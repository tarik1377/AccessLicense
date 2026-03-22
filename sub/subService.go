package sub

import (
	"encoding/base64"
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/goccy/go-json"

	"github.com/tarik1377/AccessLicense/v2/database"
	"github.com/tarik1377/AccessLicense/v2/database/model"
	"github.com/tarik1377/AccessLicense/v2/logger"
	"github.com/tarik1377/AccessLicense/v2/util/common"
	"github.com/tarik1377/AccessLicense/v2/util/random"
	"github.com/tarik1377/AccessLicense/v2/web/service"
	"github.com/tarik1377/AccessLicense/v2/xray"
)

// SubService provides business logic for generating subscription links and managing subscription data.
type SubService struct {
	showInfo       bool
	remarkModel    string
	inboundService service.InboundService
	settingService service.SettingService
}

// NewSubService creates a new subscription service with the given configuration.
func NewSubService(showInfo bool, remarkModel string) *SubService {
	return &SubService{
		showInfo:    showInfo,
		remarkModel: remarkModel,
	}
}

// GetSubs retrieves subscription links for a given subscription ID and host.
func (s *SubService) GetSubs(subId string, host string) ([]string, int64, xray.ClientTraffic, error) {
	address := host
	var result []string
	var traffic xray.ClientTraffic
	var lastOnline int64
	var clientTraffics []xray.ClientTraffic
	inbounds, err := s.getInboundsBySubId(subId)
	if err != nil {
		return nil, 0, traffic, err
	}

	if len(inbounds) == 0 {
		return nil, 0, traffic, common.NewError("No inbounds found with ", subId)
	}

	// datepicker is no longer needed in GetSubs; fetched in BuildPageData instead
	for _, inbound := range inbounds {
		clients, err := s.inboundService.GetClients(inbound)
		if err != nil {
			logger.Error("SubService - GetClients: Unable to get clients from inbound")
		}
		if clients == nil {
			continue
		}
		if len(inbound.Listen) > 0 && inbound.Listen[0] == '@' {
			listen, port, streamSettings, err := s.getFallbackMaster(inbound.Listen, inbound.StreamSettings)
			if err == nil {
				inbound.Listen = listen
				inbound.Port = port
				inbound.StreamSettings = streamSettings
			}
		}
		for _, client := range clients {
			if client.Enable && client.SubID == subId {
				link := s.getLink(inbound, client.Email, address)
				result = append(result, link)
				ct := s.getClientTraffics(inbound.ClientStats, client.Email)
				clientTraffics = append(clientTraffics, ct)
				if ct.LastOnline > lastOnline {
					lastOnline = ct.LastOnline
				}
			}
		}
	}

	// Prepare statistics
	for index, clientTraffic := range clientTraffics {
		if index == 0 {
			traffic.Up = clientTraffic.Up
			traffic.Down = clientTraffic.Down
			traffic.Total = clientTraffic.Total
			if clientTraffic.ExpiryTime > 0 {
				traffic.ExpiryTime = clientTraffic.ExpiryTime
			}
		} else {
			traffic.Up += clientTraffic.Up
			traffic.Down += clientTraffic.Down
			if traffic.Total == 0 || clientTraffic.Total == 0 {
				traffic.Total = 0
			} else {
				traffic.Total += clientTraffic.Total
			}
			if clientTraffic.ExpiryTime != traffic.ExpiryTime {
				traffic.ExpiryTime = 0
			}
		}
	}
	return result, lastOnline, traffic, nil
}

func (s *SubService) getInboundsBySubId(subId string) ([]*model.Inbound, error) {
	db := database.GetDB()
	var inbounds []*model.Inbound
	err := db.Model(model.Inbound{}).Preload("ClientStats").Where(`id in (
		SELECT DISTINCT inbounds.id
		FROM inbounds,
			JSON_EACH(JSON_EXTRACT(inbounds.settings, '$.clients')) AS client 
		WHERE
			protocol in ('vmess','vless','trojan','shadowsocks')
			AND JSON_EXTRACT(client.value, '$.subId') = ? AND enable = ?
	)`, subId, true).Find(&inbounds).Error
	if err != nil {
		return nil, err
	}
	return inbounds, nil
}

func (s *SubService) getClientTraffics(traffics []xray.ClientTraffic, email string) xray.ClientTraffic {
	for _, traffic := range traffics {
		if traffic.Email == email {
			return traffic
		}
	}
	return xray.ClientTraffic{}
}

func (s *SubService) getFallbackMaster(dest string, streamSettings string) (string, int, string, error) {
	db := database.GetDB()
	var inbound *model.Inbound
	err := db.Model(model.Inbound{}).
		Where("JSON_TYPE(settings, '$.fallbacks') = 'array'").
		Where("EXISTS (SELECT * FROM json_each(settings, '$.fallbacks') WHERE json_extract(value, '$.dest') = ?)", dest).
		Find(&inbound).Error
	if err != nil {
		return "", 0, "", err
	}

	var stream map[string]any
	json.Unmarshal([]byte(streamSettings), &stream)
	var masterStream map[string]any
	json.Unmarshal([]byte(inbound.StreamSettings), &masterStream)
	stream["security"] = masterStream["security"]
	stream["tlsSettings"] = masterStream["tlsSettings"]
	stream["externalProxy"] = masterStream["externalProxy"]
	modifiedStream, _ := json.MarshalIndent(stream, "", "  ")

	return inbound.Listen, inbound.Port, string(modifiedStream), nil
}

func (s *SubService) getLink(inbound *model.Inbound, email string, address string) string {
	switch inbound.Protocol {
	case "vmess":
		return s.genVmessLink(inbound, email, address)
	case "vless":
		return s.genVlessLink(inbound, email, address)
	case "trojan":
		return s.genTrojanLink(inbound, email, address)
	case "shadowsocks":
		return s.genShadowsocksLink(inbound, email, address)
	}
	return ""
}

func (s *SubService) genVmessLink(inbound *model.Inbound, email string, defaultAddress string) string {
	if inbound.Protocol != model.VMESS {
		return ""
	}
	var address string
	if inbound.Listen == "" || inbound.Listen == "0.0.0.0" || inbound.Listen == "::" || inbound.Listen == "::0" {
		address = defaultAddress
	} else {
		address = inbound.Listen
	}
	obj := map[string]any{
		"v":    "2",
		"add":  address,
		"port": inbound.Port,
		"type": "none",
	}
	var stream map[string]any
	json.Unmarshal([]byte(inbound.StreamSettings), &stream)
	network, _ := stream["network"].(string)
	obj["net"] = network
	switch network {
	case "tcp":
		tcp, _ := stream["tcpSettings"].(map[string]any)
		header, _ := tcp["header"].(map[string]any)
		typeStr, _ := header["type"].(string)
		obj["type"] = typeStr
		if typeStr == "http" {
			request := header["request"].(map[string]any)
			requestPath, _ := request["path"].([]any)
			obj["path"] = requestPath[0].(string)
			headers, _ := request["headers"].(map[string]any)
			obj["host"] = searchHost(headers)
		}
	case "kcp":
		kcp, _ := stream["kcpSettings"].(map[string]any)
		header, _ := kcp["header"].(map[string]any)
		obj["type"], _ = header["type"].(string)
		obj["path"], _ = kcp["seed"].(string)
	case "ws":
		ws, _ := stream["wsSettings"].(map[string]any)
		obj["path"] = ws["path"].(string)
		if host, ok := ws["host"].(string); ok && len(host) > 0 {
			obj["host"] = host
		} else {
			headers, _ := ws["headers"].(map[string]any)
			obj["host"] = searchHost(headers)
		}
	case "grpc":
		grpc, _ := stream["grpcSettings"].(map[string]any)
		obj["path"] = grpc["serviceName"].(string)
		obj["authority"] = grpc["authority"].(string)
		if grpc["multiMode"].(bool) {
			obj["type"] = "multi"
		}
	case "httpupgrade":
		httpupgrade, _ := stream["httpupgradeSettings"].(map[string]any)
		obj["path"] = httpupgrade["path"].(string)
		if host, ok := httpupgrade["host"].(string); ok && len(host) > 0 {
			obj["host"] = host
		} else {
			headers, _ := httpupgrade["headers"].(map[string]any)
			obj["host"] = searchHost(headers)
		}
	case "xhttp":
		xhttp, _ := stream["xhttpSettings"].(map[string]any)
		obj["path"] = xhttp["path"].(string)
		if host, ok := xhttp["host"].(string); ok && len(host) > 0 {
			obj["host"] = host
		} else {
			headers, _ := xhttp["headers"].(map[string]any)
			obj["host"] = searchHost(headers)
		}
		obj["mode"] = xhttp["mode"].(string)
	}
	security, _ := stream["security"].(string)
	obj["tls"] = security
	if security == "tls" {
		tlsSetting, _ := stream["tlsSettings"].(map[string]any)
		alpns, _ := tlsSetting["alpn"].([]any)
		if len(alpns) > 0 {
			var alpn []string
			for _, a := range alpns {
				alpn = append(alpn, a.(string))
			}
			obj["alpn"] = strings.Join(alpn, ",")
		}
		if sniValue, ok := searchKey(tlsSetting, "serverName"); ok {
			obj["sni"], _ = sniValue.(string)
		}

		tlsSettings, _ := searchKey(tlsSetting, "settings")
		if tlsSetting != nil {
			if fpValue, ok := searchKey(tlsSettings, "fingerprint"); ok {
				obj["fp"], _ = fpValue.(string)
			}
		}
	}

	clients, _ := s.inboundService.GetClients(inbound)
	clientIndex := -1
	for i, client := range clients {
		if client.Email == email {
			clientIndex = i
			break
		}
	}
	obj["id"] = clients[clientIndex].ID
	obj["scy"] = clients[clientIndex].Security

	externalProxies, _ := stream["externalProxy"].([]any)

	if len(externalProxies) > 0 {
		links := ""
		for index, externalProxy := range externalProxies {
			ep, _ := externalProxy.(map[string]any)
			newSecurity, _ := ep["forceTls"].(string)
			newObj := map[string]any{}
			for key, value := range obj {
				if !(newSecurity == "none" && (key == "alpn" || key == "sni" || key == "fp")) {
					newObj[key] = value
				}
			}
			newObj["ps"] = s.genRemark(inbound, email, ep["remark"].(string))
			newObj["add"] = ep["dest"].(string)
			newObj["port"] = int(ep["port"].(float64))

			if newSecurity != "same" {
				newObj["tls"] = newSecurity
			}
			if index > 0 {
				links += "\n"
			}
			jsonStr, _ := json.MarshalIndent(newObj, "", "  ")
			links += "vmess://" + base64.StdEncoding.EncodeToString(jsonStr)
		}
		return links
	}

	obj["ps"] = s.genRemark(inbound, email, "")

	jsonStr, _ := json.MarshalIndent(obj, "", "  ")
	return "vmess://" + base64.StdEncoding.EncodeToString(jsonStr)
}

func (s *SubService) genVlessLink(inbound *model.Inbound, email string, defaultAddress string) string {
	var address string
	if inbound.Listen == "" || inbound.Listen == "0.0.0.0" || inbound.Listen == "::" || inbound.Listen == "::0" {
		address = defaultAddress
	} else {
		address = inbound.Listen
	}

	if inbound.Protocol != model.VLESS {
		return ""
	}
	var stream map[string]any
	json.Unmarshal([]byte(inbound.StreamSettings), &stream)
	clients, _ := s.inboundService.GetClients(inbound)
	clientIndex := -1
	for i, client := range clients {
		if client.Email == email {
			clientIndex = i
			break
		}
	}
	uuid := clients[clientIndex].ID
	port := inbound.Port
	streamNetwork := stream["network"].(string)
	params := make(map[string]string)
	params["type"] = streamNetwork

	// Add encryption parameter for VLESS from inbound settings
	var settings map[string]any
	json.Unmarshal([]byte(inbound.Settings), &settings)
	if encryption, ok := settings["encryption"].(string); ok {
		params["encryption"] = encryption
	}

	switch streamNetwork {
	case "tcp":
		tcp, _ := stream["tcpSettings"].(map[string]any)
		header, _ := tcp["header"].(map[string]any)
		typeStr, _ := header["type"].(string)
		if typeStr == "http" {
			request := header["request"].(map[string]any)
			requestPath, _ := request["path"].([]any)
			params["path"] = requestPath[0].(string)
			headers, _ := request["headers"].(map[string]any)
			params["host"] = searchHost(headers)
			params["headerType"] = "http"
		}
	case "kcp":
		kcp, _ := stream["kcpSettings"].(map[string]any)
		header, _ := kcp["header"].(map[string]any)
		params["headerType"] = header["type"].(string)
		params["seed"] = kcp["seed"].(string)
	case "ws":
		ws, _ := stream["wsSettings"].(map[string]any)
		params["path"] = ws["path"].(string)
		if host, ok := ws["host"].(string); ok && len(host) > 0 {
			params["host"] = host
		} else {
			headers, _ := ws["headers"].(map[string]any)
			params["host"] = searchHost(headers)
		}
	case "grpc":
		grpc, _ := stream["grpcSettings"].(map[string]any)
		params["serviceName"] = grpc["serviceName"].(string)
		params["authority"], _ = grpc["authority"].(string)
		if grpc["multiMode"].(bool) {
			params["mode"] = "multi"
		}
	case "httpupgrade":
		httpupgrade, _ := stream["httpupgradeSettings"].(map[string]any)
		params["path"] = httpupgrade["path"].(string)
		if host, ok := httpupgrade["host"].(string); ok && len(host) > 0 {
			params["host"] = host
		} else {
			headers, _ := httpupgrade["headers"].(map[string]any)
			params["host"] = searchHost(headers)
		}
	case "xhttp":
		xhttp, _ := stream["xhttpSettings"].(map[string]any)
		params["path"] = xhttp["path"].(string)
		if host, ok := xhttp["host"].(string); ok && len(host) > 0 {
			params["host"] = host
		} else {
			headers, _ := xhttp["headers"].(map[string]any)
			params["host"] = searchHost(headers)
		}
		params["mode"] = xhttp["mode"].(string)
	}
	security, _ := stream["security"].(string)
	if security == "tls" {
		params["security"] = "tls"
		tlsSetting, _ := stream["tlsSettings"].(map[string]any)
		alpns, _ := tlsSetting["alpn"].([]any)
		var alpn []string
		for _, a := range alpns {
			alpn = append(alpn, a.(string))
		}
		if len(alpn) > 0 {
			params["alpn"] = strings.Join(alpn, ",")
		}
		if sniValue, ok := searchKey(tlsSetting, "serverName"); ok {
			params["sni"], _ = sniValue.(string)
		}

		tlsSettings, _ := searchKey(tlsSetting, "settings")
		if tlsSetting != nil {
			if fpValue, ok := searchKey(tlsSettings, "fingerprint"); ok {
				fp, _ := fpValue.(string)
				params["fp"] = getFingerprint(fp)
			}
		}

		if streamNetwork == "tcp" && len(clients[clientIndex].Flow) > 0 {
			params["flow"] = clients[clientIndex].Flow
		}
	}

	if security == "reality" {
		params["security"] = "reality"
		realitySetting, _ := stream["realitySettings"].(map[string]any)
		realitySettings, _ := searchKey(realitySetting, "settings")
		if realitySetting != nil {
			if sniValue, ok := searchKey(realitySetting, "serverNames"); ok {
				sNames, _ := sniValue.([]any)
				params["sni"] = sNames[random.Num(len(sNames))].(string)
			}
			if pbkValue, ok := searchKey(realitySettings, "publicKey"); ok {
				params["pbk"], _ = pbkValue.(string)
			}
			if sidValue, ok := searchKey(realitySetting, "shortIds"); ok {
				shortIds, _ := sidValue.([]any)
				params["sid"] = shortIds[random.Num(len(shortIds))].(string)
			}
			if fpValue, ok := searchKey(realitySettings, "fingerprint"); ok {
				if fp, ok := fpValue.(string); ok && len(fp) > 0 {
					params["fp"] = getFingerprint(fp)
				}
			}
			if pqvValue, ok := searchKey(realitySettings, "mldsa65Verify"); ok {
				if pqv, ok := pqvValue.(string); ok && len(pqv) > 0 {
					params["pqv"] = pqv
				}
			}
			realityDest, _ := realitySetting["dest"].(string)
			params["spx"] = generateSpiderXForDest(realityDest)
		}

		if streamNetwork == "tcp" && len(clients[clientIndex].Flow) > 0 {
			params["flow"] = clients[clientIndex].Flow
		}
	}

	if security != "tls" && security != "reality" {
		params["security"] = "none"
	}

	externalProxies, _ := stream["externalProxy"].([]any)

	if len(externalProxies) > 0 {
		links := make([]string, 0, len(externalProxies))
		for _, externalProxy := range externalProxies {
			ep, _ := externalProxy.(map[string]any)
			newSecurity, _ := ep["forceTls"].(string)
			dest, _ := ep["dest"].(string)
			port := int(ep["port"].(float64))
			link := fmt.Sprintf("vless://%s@%s:%d", uuid, dest, port)

			if newSecurity != "same" {
				params["security"] = newSecurity
			} else {
				params["security"] = security
			}
			url, _ := url.Parse(link)
			q := url.Query()

			for k, v := range params {
				if !(newSecurity == "none" && (k == "alpn" || k == "sni" || k == "fp")) {
					q.Add(k, v)
				}
			}

			// Set the new query values on the URL
			url.RawQuery = q.Encode()

			url.Fragment = s.genRemark(inbound, email, ep["remark"].(string))

			links = append(links, url.String())
		}
		return strings.Join(links, "\n")
	}

	link := fmt.Sprintf("vless://%s@%s:%d", uuid, address, port)
	url, _ := url.Parse(link)
	q := url.Query()

	for k, v := range params {
		q.Add(k, v)
	}

	// Set the new query values on the URL
	url.RawQuery = q.Encode()

	url.Fragment = s.genRemark(inbound, email, "")
	return url.String()
}

func (s *SubService) genTrojanLink(inbound *model.Inbound, email string, defaultAddress string) string {
	var address string
	if inbound.Listen == "" || inbound.Listen == "0.0.0.0" || inbound.Listen == "::" || inbound.Listen == "::0" {
		address = defaultAddress
	} else {
		address = inbound.Listen
	}
	if inbound.Protocol != model.Trojan {
		return ""
	}
	var stream map[string]any
	json.Unmarshal([]byte(inbound.StreamSettings), &stream)
	clients, _ := s.inboundService.GetClients(inbound)
	clientIndex := -1
	for i, client := range clients {
		if client.Email == email {
			clientIndex = i
			break
		}
	}
	password := clients[clientIndex].Password
	port := inbound.Port
	streamNetwork := stream["network"].(string)
	params := make(map[string]string)
	params["type"] = streamNetwork

	switch streamNetwork {
	case "tcp":
		tcp, _ := stream["tcpSettings"].(map[string]any)
		header, _ := tcp["header"].(map[string]any)
		typeStr, _ := header["type"].(string)
		if typeStr == "http" {
			request := header["request"].(map[string]any)
			requestPath, _ := request["path"].([]any)
			params["path"] = requestPath[0].(string)
			headers, _ := request["headers"].(map[string]any)
			params["host"] = searchHost(headers)
			params["headerType"] = "http"
		}
	case "kcp":
		kcp, _ := stream["kcpSettings"].(map[string]any)
		header, _ := kcp["header"].(map[string]any)
		params["headerType"] = header["type"].(string)
		params["seed"] = kcp["seed"].(string)
	case "ws":
		ws, _ := stream["wsSettings"].(map[string]any)
		params["path"] = ws["path"].(string)
		if host, ok := ws["host"].(string); ok && len(host) > 0 {
			params["host"] = host
		} else {
			headers, _ := ws["headers"].(map[string]any)
			params["host"] = searchHost(headers)
		}
	case "grpc":
		grpc, _ := stream["grpcSettings"].(map[string]any)
		params["serviceName"] = grpc["serviceName"].(string)
		params["authority"], _ = grpc["authority"].(string)
		if grpc["multiMode"].(bool) {
			params["mode"] = "multi"
		}
	case "httpupgrade":
		httpupgrade, _ := stream["httpupgradeSettings"].(map[string]any)
		params["path"] = httpupgrade["path"].(string)
		if host, ok := httpupgrade["host"].(string); ok && len(host) > 0 {
			params["host"] = host
		} else {
			headers, _ := httpupgrade["headers"].(map[string]any)
			params["host"] = searchHost(headers)
		}
	case "xhttp":
		xhttp, _ := stream["xhttpSettings"].(map[string]any)
		params["path"] = xhttp["path"].(string)
		if host, ok := xhttp["host"].(string); ok && len(host) > 0 {
			params["host"] = host
		} else {
			headers, _ := xhttp["headers"].(map[string]any)
			params["host"] = searchHost(headers)
		}
		params["mode"] = xhttp["mode"].(string)
	}
	security, _ := stream["security"].(string)
	if security == "tls" {
		params["security"] = "tls"
		tlsSetting, _ := stream["tlsSettings"].(map[string]any)
		alpns, _ := tlsSetting["alpn"].([]any)
		var alpn []string
		for _, a := range alpns {
			alpn = append(alpn, a.(string))
		}
		if len(alpn) > 0 {
			params["alpn"] = strings.Join(alpn, ",")
		}
		if sniValue, ok := searchKey(tlsSetting, "serverName"); ok {
			params["sni"], _ = sniValue.(string)
		}

		tlsSettings, _ := searchKey(tlsSetting, "settings")
		if tlsSetting != nil {
			if fpValue, ok := searchKey(tlsSettings, "fingerprint"); ok {
				fp, _ := fpValue.(string)
				params["fp"] = getFingerprint(fp)
			}
		}
	}

	if security == "reality" {
		params["security"] = "reality"
		realitySetting, _ := stream["realitySettings"].(map[string]any)
		realitySettings, _ := searchKey(realitySetting, "settings")
		if realitySetting != nil {
			if sniValue, ok := searchKey(realitySetting, "serverNames"); ok {
				sNames, _ := sniValue.([]any)
				params["sni"] = sNames[random.Num(len(sNames))].(string)
			}
			if pbkValue, ok := searchKey(realitySettings, "publicKey"); ok {
				params["pbk"], _ = pbkValue.(string)
			}
			if sidValue, ok := searchKey(realitySetting, "shortIds"); ok {
				shortIds, _ := sidValue.([]any)
				params["sid"] = shortIds[random.Num(len(shortIds))].(string)
			}
			if fpValue, ok := searchKey(realitySettings, "fingerprint"); ok {
				if fp, ok := fpValue.(string); ok && len(fp) > 0 {
					params["fp"] = getFingerprint(fp)
				}
			}
			if pqvValue, ok := searchKey(realitySettings, "mldsa65Verify"); ok {
				if pqv, ok := pqvValue.(string); ok && len(pqv) > 0 {
					params["pqv"] = pqv
				}
			}
			realityDest, _ := realitySetting["dest"].(string)
			params["spx"] = generateSpiderXForDest(realityDest)
		}

		if streamNetwork == "tcp" && len(clients[clientIndex].Flow) > 0 {
			params["flow"] = clients[clientIndex].Flow
		}
	}

	if security != "tls" && security != "reality" {
		params["security"] = "none"
	}

	externalProxies, _ := stream["externalProxy"].([]any)

	if len(externalProxies) > 0 {
		links := ""
		for index, externalProxy := range externalProxies {
			ep, _ := externalProxy.(map[string]any)
			newSecurity, _ := ep["forceTls"].(string)
			dest, _ := ep["dest"].(string)
			port := int(ep["port"].(float64))
			link := fmt.Sprintf("trojan://%s@%s:%d", password, dest, port)

			if newSecurity != "same" {
				params["security"] = newSecurity
			} else {
				params["security"] = security
			}
			url, _ := url.Parse(link)
			q := url.Query()

			for k, v := range params {
				if !(newSecurity == "none" && (k == "alpn" || k == "sni" || k == "fp")) {
					q.Add(k, v)
				}
			}

			// Set the new query values on the URL
			url.RawQuery = q.Encode()

			url.Fragment = s.genRemark(inbound, email, ep["remark"].(string))

			if index > 0 {
				links += "\n"
			}
			links += url.String()
		}
		return links
	}

	link := fmt.Sprintf("trojan://%s@%s:%d", password, address, port)

	url, _ := url.Parse(link)
	q := url.Query()

	for k, v := range params {
		q.Add(k, v)
	}

	// Set the new query values on the URL
	url.RawQuery = q.Encode()

	url.Fragment = s.genRemark(inbound, email, "")
	return url.String()
}

func (s *SubService) genShadowsocksLink(inbound *model.Inbound, email string, defaultAddress string) string {
	var address string
	if inbound.Listen == "" || inbound.Listen == "0.0.0.0" || inbound.Listen == "::" || inbound.Listen == "::0" {
		address = defaultAddress
	} else {
		address = inbound.Listen
	}
	if inbound.Protocol != model.Shadowsocks {
		return ""
	}
	var stream map[string]any
	json.Unmarshal([]byte(inbound.StreamSettings), &stream)
	clients, _ := s.inboundService.GetClients(inbound)

	var settings map[string]any
	json.Unmarshal([]byte(inbound.Settings), &settings)
	inboundPassword := settings["password"].(string)
	method := settings["method"].(string)
	clientIndex := -1
	for i, client := range clients {
		if client.Email == email {
			clientIndex = i
			break
		}
	}
	streamNetwork := stream["network"].(string)
	params := make(map[string]string)
	params["type"] = streamNetwork

	switch streamNetwork {
	case "tcp":
		tcp, _ := stream["tcpSettings"].(map[string]any)
		header, _ := tcp["header"].(map[string]any)
		typeStr, _ := header["type"].(string)
		if typeStr == "http" {
			request := header["request"].(map[string]any)
			requestPath, _ := request["path"].([]any)
			params["path"] = requestPath[0].(string)
			headers, _ := request["headers"].(map[string]any)
			params["host"] = searchHost(headers)
			params["headerType"] = "http"
		}
	case "kcp":
		kcp, _ := stream["kcpSettings"].(map[string]any)
		header, _ := kcp["header"].(map[string]any)
		params["headerType"] = header["type"].(string)
		params["seed"] = kcp["seed"].(string)
	case "ws":
		ws, _ := stream["wsSettings"].(map[string]any)
		params["path"] = ws["path"].(string)
		if host, ok := ws["host"].(string); ok && len(host) > 0 {
			params["host"] = host
		} else {
			headers, _ := ws["headers"].(map[string]any)
			params["host"] = searchHost(headers)
		}
	case "grpc":
		grpc, _ := stream["grpcSettings"].(map[string]any)
		params["serviceName"] = grpc["serviceName"].(string)
		params["authority"], _ = grpc["authority"].(string)
		if grpc["multiMode"].(bool) {
			params["mode"] = "multi"
		}
	case "httpupgrade":
		httpupgrade, _ := stream["httpupgradeSettings"].(map[string]any)
		params["path"] = httpupgrade["path"].(string)
		if host, ok := httpupgrade["host"].(string); ok && len(host) > 0 {
			params["host"] = host
		} else {
			headers, _ := httpupgrade["headers"].(map[string]any)
			params["host"] = searchHost(headers)
		}
	case "xhttp":
		xhttp, _ := stream["xhttpSettings"].(map[string]any)
		params["path"] = xhttp["path"].(string)
		if host, ok := xhttp["host"].(string); ok && len(host) > 0 {
			params["host"] = host
		} else {
			headers, _ := xhttp["headers"].(map[string]any)
			params["host"] = searchHost(headers)
		}
		params["mode"] = xhttp["mode"].(string)
	}

	security, _ := stream["security"].(string)
	if security == "tls" {
		params["security"] = "tls"
		tlsSetting, _ := stream["tlsSettings"].(map[string]any)
		alpns, _ := tlsSetting["alpn"].([]any)
		var alpn []string
		for _, a := range alpns {
			alpn = append(alpn, a.(string))
		}
		if len(alpn) > 0 {
			params["alpn"] = strings.Join(alpn, ",")
		}
		if sniValue, ok := searchKey(tlsSetting, "serverName"); ok {
			params["sni"], _ = sniValue.(string)
		}

		tlsSettings, _ := searchKey(tlsSetting, "settings")
		if tlsSetting != nil {
			if fpValue, ok := searchKey(tlsSettings, "fingerprint"); ok {
				fp, _ := fpValue.(string)
				params["fp"] = getFingerprint(fp)
			}
		}
	}

	encPart := fmt.Sprintf("%s:%s", method, clients[clientIndex].Password)
	if method[0] == '2' {
		encPart = fmt.Sprintf("%s:%s:%s", method, inboundPassword, clients[clientIndex].Password)
	}

	externalProxies, _ := stream["externalProxy"].([]any)

	if len(externalProxies) > 0 {
		links := ""
		for index, externalProxy := range externalProxies {
			ep, _ := externalProxy.(map[string]any)
			newSecurity, _ := ep["forceTls"].(string)
			dest, _ := ep["dest"].(string)
			port := int(ep["port"].(float64))
			link := fmt.Sprintf("ss://%s@%s:%d", base64.StdEncoding.EncodeToString([]byte(encPart)), dest, port)

			if newSecurity != "same" {
				params["security"] = newSecurity
			} else {
				params["security"] = security
			}
			url, _ := url.Parse(link)
			q := url.Query()

			for k, v := range params {
				if !(newSecurity == "none" && (k == "alpn" || k == "sni" || k == "fp")) {
					q.Add(k, v)
				}
			}

			// Set the new query values on the URL
			url.RawQuery = q.Encode()

			url.Fragment = s.genRemark(inbound, email, ep["remark"].(string))

			if index > 0 {
				links += "\n"
			}
			links += url.String()
		}
		return links
	}

	link := fmt.Sprintf("ss://%s@%s:%d", base64.StdEncoding.EncodeToString([]byte(encPart)), address, inbound.Port)
	url, _ := url.Parse(link)
	q := url.Query()

	for k, v := range params {
		q.Add(k, v)
	}

	// Set the new query values on the URL
	url.RawQuery = q.Encode()

	url.Fragment = s.genRemark(inbound, email, "")
	return url.String()
}

func (s *SubService) genRemark(inbound *model.Inbound, email string, extra string) string {
	separationChar := string(s.remarkModel[0])
	orderChars := s.remarkModel[1:]
	orders := map[byte]string{
		'i': "",
		'e': "",
		'o': "",
	}
	if len(email) > 0 {
		orders['e'] = email
	}
	if len(inbound.Remark) > 0 {
		orders['i'] = inbound.Remark
	}
	if len(extra) > 0 {
		orders['o'] = extra
	}

	var remark []string
	for i := 0; i < len(orderChars); i++ {
		char := orderChars[i]
		order, exists := orders[char]
		if exists && order != "" {
			remark = append(remark, order)
		}
	}

	if s.showInfo {
		statsExist := false
		var stats xray.ClientTraffic
		for _, clientStat := range inbound.ClientStats {
			if clientStat.Email == email {
				stats = clientStat
				statsExist = true
				break
			}
		}

		// Get remained days
		if statsExist {
			if !stats.Enable {
				return fmt.Sprintf("⛔️N/A%s%s", separationChar, strings.Join(remark, separationChar))
			}
			if vol := stats.Total - (stats.Up + stats.Down); vol > 0 {
				remark = append(remark, fmt.Sprintf("%s%s", common.FormatTraffic(vol), "📊"))
			}
			now := time.Now().Unix()
			switch exp := stats.ExpiryTime / 1000; {
			case exp > 0:
				remainingSeconds := exp - now
				days := remainingSeconds / 86400
				hours := (remainingSeconds % 86400) / 3600
				minutes := (remainingSeconds % 3600) / 60
				if days > 0 {
					if hours > 0 {
						remark = append(remark, fmt.Sprintf("%dD,%dH⏳", days, hours))
					} else {
						remark = append(remark, fmt.Sprintf("%dD⏳", days))
					}
				} else if hours > 0 {
					remark = append(remark, fmt.Sprintf("%dH⏳", hours))
				} else {
					remark = append(remark, fmt.Sprintf("%dM⏳", minutes))
				}
			case exp < 0:
				days := exp / -86400
				hours := (exp % -86400) / 3600
				minutes := (exp % -3600) / 60
				if days > 0 {
					if hours > 0 {
						remark = append(remark, fmt.Sprintf("%dD,%dH⏳", days, hours))
					} else {
						remark = append(remark, fmt.Sprintf("%dD⏳", days))
					}
				} else if hours > 0 {
					remark = append(remark, fmt.Sprintf("%dH⏳", hours))
				} else {
					remark = append(remark, fmt.Sprintf("%dM⏳", minutes))
				}
			}
		}
	}
	return strings.Join(remark, separationChar)
}

// getFingerprint returns the fingerprint to use for link generation.
// If fp is empty or "random", a random fingerprint is chosen from a predefined list.
// Otherwise, the original fp value is returned as-is.
func getFingerprint(fp string) string {
	if fp == "" || fp == "random" {
		fingerprints := []string{"chrome", "firefox", "safari", "edge"}
		return fingerprints[random.Num(len(fingerprints))]
	}
	return fp
}

// generateRealisticSpiderX creates browser-like URL paths for Reality SpiderX
// to avoid DPI detection of static/predictable patterns
func generateRealisticSpiderX() string {
	timestamp := fmt.Sprintf("%d", time.Now().Unix())
	sessionId := random.Seq(12)

	paths := []string{
		// Generic website paths
		"/",
		"/en",
		"/en-us",
		"/search?q=" + random.Seq(8),
		"/products",
		"/about",
		"/support",
		"/docs/" + random.Seq(6),
		"/blog/" + random.Seq(10),
		"/?lang=en&ref=" + random.Seq(6),

		// CDN / Cloudflare-style paths
		"/cdn-cgi/trace",
		"/cdn-cgi/scripts/" + random.Seq(10) + "/cloudflare-static/email-decode.min.js",
		"/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1?ray=" + random.Seq(16),
		"/cdn-cgi/rum?req=" + random.Seq(20) + "&t=" + timestamp,
		"/ajax/libs/jquery/3.7.1/jquery.min.js",
		"/ajax/libs/font-awesome/6.5.1/css/all.min.css",

		// Asset / chunk paths (Webpack/Vite style)
		"/assets/js/chunk-" + random.Seq(8) + ".js",
		"/assets/js/vendor." + random.Seq(12) + ".js",
		"/assets/css/app." + random.Seq(8) + ".css",
		"/static/js/app." + random.Seq(8) + ".js",
		"/static/js/" + random.Seq(4) + "." + random.Seq(8) + ".chunk.js",
		"/static/media/" + random.Seq(10) + "." + random.Seq(8) + ".woff2",
		"/_next/static/chunks/pages/_app-" + random.Seq(16) + ".js",
		"/_next/static/" + random.Seq(20) + "/_buildManifest.js",
		"/_next/image?url=%2Fimages%2F" + random.Seq(8) + ".webp&w=1920&q=75",
		"/images/" + random.Seq(12) + ".png",
		"/assets/css/main.css",

		// Microsoft-style paths
		"/en-us/windows/get-started/",
		"/en-us/microsoft-365/business/compare-all-plans?activetab=tab:primaryr2",
		"/en-us/edge/welcome?form=" + random.Seq(6) + "&channel=stable",
		"/msdownload/update/v3/static/trustedr/en/authrootstl.cab?t=" + timestamp,
		"/v1.0/me/drive/root/children?$top=20&sid=" + sessionId,
		"/onenote/v1.0/pages?$filter=createdDateTime ge " + random.Seq(10),
		"/identity/v1.0/.well-known/openid-configuration",

		// Apple-style paths
		"/v1/config?t=" + timestamp + "&sid=" + sessionId,
		"/retail/availability?product=MYW73LL/A&location=" + random.Seq(5),
		"/shop/go/account/orders?t=" + timestamp,
		"/105/media/us/iphone/family/" + random.Seq(12) + "/hero_" + random.Seq(6) + ".jpg",
		"/services/i/identify?build=" + random.Seq(5) + "&clientId=" + random.Seq(16),

		// API versioned paths (telemetry/config)
		"/api/v1/" + random.Seq(8),
		"/api/v2/telemetry?sid=" + sessionId + "&t=" + timestamp,
		"/api/v2/events?batch=" + random.Seq(6) + "&seq=" + random.Seq(3),
		"/api/v3/config?app=" + random.Seq(8) + "&ver=2.1." + random.Seq(2),
		"/api/v3/heartbeat?uid=" + random.Seq(16),
		"/api/v1/session/renew?token=" + random.Seq(24),
		"/graphql?operationName=" + random.Seq(10) + "&variables=%7B%7D",

		// Query parameters with timestamp/session
		"/collect?v=2&tid=G-" + random.Seq(10) + "&cid=" + random.Seq(16) + "&t=" + timestamp,
		"/r/collect?v=1&_v=j101&a=" + random.Seq(9) + "&t=pageview&_s=1&dl=https%3A%2F%2Fwww." + random.Seq(8) + ".com",
		"/log?type=performance&sid=" + sessionId + "&t=" + timestamp + "&dur=" + random.Seq(3),

		// Referer-like browsing paths
		"/en-us/windows/get-started/set-up-your-pc",
		"/en-us/learn/modules/introduction-to-azure/",
		"/en-us/training/paths/azure-fundamentals/",
		"/support/en-us/topic/" + random.Seq(8),
		"/store/category/devices?icid=" + random.Seq(12),
		"/privacy/privacystatement?t=" + timestamp,
	}
	return paths[random.Num(len(paths))]
}

// generateSpiderXForDest creates domain-specific browser-like URL paths for Reality SpiderX
func generateSpiderXForDest(dest string) string {
	// Strip port if present (e.g. "www.microsoft.com:443" -> "www.microsoft.com")
	host := dest
	if h, _, err := net.SplitHostPort(dest); err == nil {
		host = h
	}

	timestamp := fmt.Sprintf("%d", time.Now().Unix())
	sessionId := random.Seq(12)

	switch {
	case strings.HasSuffix(host, "microsoft.com"):
		paths := []string{
			"/en-us/windows/get-started/",
			"/en-us/microsoft-365/",
			"/msdownload/update/v3/static/trustedr/en/authrootstl.cab?t=" + timestamp,
			"/v1.0/me/drive/root/children?$top=20&sid=" + sessionId,
			"/identity/v1.0/.well-known/openid-configuration",
		}
		return paths[random.Num(len(paths))]

	case strings.HasSuffix(host, "apple.com"):
		paths := []string{
			"/retail/availability?product=MK2N3",
			"/v1/config",
			"/services/i/identify",
			"/shop/go/product/iphone_15",
			"/today/",
		}
		return paths[random.Num(len(paths))]

	case strings.HasSuffix(host, "google.com"):
		paths := []string{
			"/dl/android/aosp/taimen-factory.zip",
			"/chrome/answer/95346",
			"/search?q=weather",
			"/maps/api/js?v=3",
		}
		return paths[random.Num(len(paths))]

	case host == "yandex.ru" || host == "ya.ru" ||
		strings.HasSuffix(host, ".yandex.ru") ||
		strings.HasSuffix(host, ".yandexcloud.net") ||
		host == "yastatic.net" || strings.HasSuffix(host, ".yastatic.net"):
		paths := []string{
			"/search?text=%D0%BF%D0%BE%D0%B3%D0%BE%D0%B4%D0%B0+%D0%BC%D0%BE%D1%81%D0%BA%D0%B2%D0%B0&lr=213&sid=" + sessionId,
			"/images/search?text=%D0%BA%D0%BE%D1%82%D0%B8%D0%BA%D0%B8&t=" + timestamp,
			"/weather/moscow",
			"/news/",
			"/maps/?ll=37.6173,55.7558&z=10&sid=" + sessionId,
			"/market/product/" + fmt.Sprintf("%d", 10000+random.Num(90000)),
			"/video/search?text=%D0%BA%D0%B0%D0%BA+%D0%B3%D0%BE%D1%82%D0%BE%D0%B2%D0%B8%D1%82%D1%8C",
			"/watch/" + fmt.Sprintf("%d", 10000000+random.Num(90000000)),
			"/metrika/tag.js?t=" + timestamp,
			"/d/" + random.Seq(8),
			"/client/disk",
			"/handlers/track.jsx?track=" + fmt.Sprintf("%d", 10000+random.Num(90000)),
			"/folders/" + random.Seq(8),
			"/compute/instances?sid=" + sessionId,
		}
		return paths[random.Num(len(paths))]

	case host == "vk.com":
		paths := []string{
			"/feed",
			"/im",
			"/video/playlist/-" + fmt.Sprintf("%d", 10000+random.Num(90000)) + "_1",
			"/wall-" + fmt.Sprintf("%d_%d", 10000+random.Num(90000), 10000+random.Num(90000)),
			"/away.php?to=https%3A%2F%2Fexample.com&t=" + timestamp,
			"/sticker/1-" + fmt.Sprintf("%d", 10000+random.Num(90000)),
		}
		return paths[random.Num(len(paths))]

	case host == "sberbank.ru" || strings.HasSuffix(host, ".sberbank.ru"):
		paths := []string{
			"/api/v1/account/info?sid=" + sessionId,
			"/online/",
			"/estore/",
			"/sms/pbx/api/v2/config",
		}
		return paths[random.Num(len(paths))]

	case host == "mail.ru" || strings.HasSuffix(host, ".mail.ru"):
		paths := []string{
			"/inbox/?t=" + timestamp,
			"/api/v1/messages?sid=" + sessionId,
			"/calendar/",
			"/cloud/",
		}
		return paths[random.Num(len(paths))]

	case strings.HasSuffix(host, "max.ru"):
		paths := []string{
			"/personal/",
			"/services/",
			"/api/v1/account",
			"/tariffs/",
			"/support/",
		}
		return paths[random.Num(len(paths))]

	default:
		return generateRealisticSpiderX()
	}
}

func searchKey(data any, key string) (any, bool) {
	switch val := data.(type) {
	case map[string]any:
		for k, v := range val {
			if k == key {
				return v, true
			}
			if result, ok := searchKey(v, key); ok {
				return result, true
			}
		}
	case []any:
		for _, v := range val {
			if result, ok := searchKey(v, key); ok {
				return result, true
			}
		}
	}
	return nil, false
}

func searchHost(headers any) string {
	data, _ := headers.(map[string]any)
	for k, v := range data {
		if strings.EqualFold(k, "host") {
			switch v.(type) {
			case []any:
				hosts, _ := v.([]any)
				if len(hosts) > 0 {
					return hosts[0].(string)
				} else {
					return ""
				}
			case any:
				return v.(string)
			}
		}
	}

	return ""
}

// PageData is a view model for subpage.html
// PageData contains data for rendering the subscription information page.
type PageData struct {
	Host         string
	BasePath     string
	SId          string
	Download     string
	Upload       string
	Total        string
	Used         string
	Remained     string
	Expire       int64
	LastOnline   int64
	Datepicker   string
	DownloadByte int64
	UploadByte   int64
	TotalByte    int64
	SubUrl       string
	SubJsonUrl   string
	Result       []string
}

// ResolveRequest extracts scheme and host info from request/headers consistently.
// ResolveRequest extracts scheme, host, and header information from an HTTP request.
func (s *SubService) ResolveRequest(c *gin.Context) (scheme string, host string, hostWithPort string, hostHeader string) {
	// scheme
	scheme = "http"
	if c.Request.TLS != nil || strings.EqualFold(c.GetHeader("X-Forwarded-Proto"), "https") {
		scheme = "https"
	}

	// base host (no port)
	if h, err := getHostFromXFH(c.GetHeader("X-Forwarded-Host")); err == nil && h != "" {
		host = h
	}
	if host == "" {
		host = c.GetHeader("X-Real-IP")
	}
	if host == "" {
		var err error
		host, _, err = net.SplitHostPort(c.Request.Host)
		if err != nil {
			host = c.Request.Host
		}
	}

	// host:port for URLs
	hostWithPort = c.GetHeader("X-Forwarded-Host")
	if hostWithPort == "" {
		hostWithPort = c.Request.Host
	}
	if hostWithPort == "" {
		hostWithPort = host
	}

	// header display host
	hostHeader = c.GetHeader("X-Forwarded-Host")
	if hostHeader == "" {
		hostHeader = c.GetHeader("X-Real-IP")
	}
	if hostHeader == "" {
		hostHeader = host
	}
	return
}

// BuildURLs constructs absolute subscription and JSON subscription URLs for a given subscription ID.
// It prioritizes configured URIs, then individual settings, and finally falls back to request-derived components.
func (s *SubService) BuildURLs(scheme, hostWithPort, subPath, subJsonPath, subId string) (subURL, subJsonURL string) {
	// Input validation
	if subId == "" {
		return "", ""
	}

	// Get configured URIs first (highest priority)
	configuredSubURI, _ := s.settingService.GetSubURI()
	configuredSubJsonURI, _ := s.settingService.GetSubJsonURI()

	// Determine base scheme and host (cached to avoid duplicate calls)
	var baseScheme, baseHostWithPort string
	if configuredSubURI == "" || configuredSubJsonURI == "" {
		baseScheme, baseHostWithPort = s.getBaseSchemeAndHost(scheme, hostWithPort)
	}

	// Build subscription URL
	subURL = s.buildSingleURL(configuredSubURI, baseScheme, baseHostWithPort, subPath, subId)

	// Build JSON subscription URL
	subJsonURL = s.buildSingleURL(configuredSubJsonURI, baseScheme, baseHostWithPort, subJsonPath, subId)

	return subURL, subJsonURL
}

// getBaseSchemeAndHost determines the base scheme and host from settings or falls back to request values
func (s *SubService) getBaseSchemeAndHost(requestScheme, requestHostWithPort string) (string, string) {
	subDomain, err := s.settingService.GetSubDomain()
	if err != nil || subDomain == "" {
		return requestScheme, requestHostWithPort
	}

	// Get port and TLS settings
	subPort, _ := s.settingService.GetSubPort()
	subKeyFile, _ := s.settingService.GetSubKeyFile()
	subCertFile, _ := s.settingService.GetSubCertFile()

	// Determine scheme from TLS configuration
	scheme := "http"
	if subKeyFile != "" && subCertFile != "" {
		scheme = "https"
	}

	// Build host:port, always include port for clarity
	hostWithPort := fmt.Sprintf("%s:%d", subDomain, subPort)

	return scheme, hostWithPort
}

// buildSingleURL constructs a single URL using configured URI or base components
func (s *SubService) buildSingleURL(configuredURI, baseScheme, baseHostWithPort, basePath, subId string) string {
	if configuredURI != "" {
		return s.joinPathWithID(configuredURI, subId)
	}

	baseURL := fmt.Sprintf("%s://%s", baseScheme, baseHostWithPort)
	return s.joinPathWithID(baseURL+basePath, subId)
}

// joinPathWithID safely joins a base path with a subscription ID
func (s *SubService) joinPathWithID(basePath, subId string) string {
	if strings.HasSuffix(basePath, "/") {
		return basePath + subId
	}
	return basePath + "/" + subId
}

// BuildPageData parses header and prepares the template view model.
// BuildPageData constructs page data for rendering the subscription information page.
func (s *SubService) BuildPageData(subId string, hostHeader string, traffic xray.ClientTraffic, lastOnline int64, subs []string, subURL, subJsonURL string, basePath string) PageData {
	download := common.FormatTraffic(traffic.Down)
	upload := common.FormatTraffic(traffic.Up)
	total := "∞"
	used := common.FormatTraffic(traffic.Up + traffic.Down)
	remained := ""
	if traffic.Total > 0 {
		total = common.FormatTraffic(traffic.Total)
		left := max(traffic.Total-(traffic.Up+traffic.Down), 0)
		remained = common.FormatTraffic(left)
	}

	datepicker, err := s.settingService.GetDatepicker()
	if err != nil || datepicker == "" {
		datepicker = "gregorian"
	}

	return PageData{
		Host:         hostHeader,
		BasePath:     basePath,
		SId:          subId,
		Download:     download,
		Upload:       upload,
		Total:        total,
		Used:         used,
		Remained:     remained,
		Expire:       traffic.ExpiryTime / 1000,
		LastOnline:   lastOnline,
		Datepicker:   datepicker,
		DownloadByte: traffic.Down,
		UploadByte:   traffic.Up,
		TotalByte:    traffic.Total,
		SubUrl:       subURL,
		SubJsonUrl:   subJsonURL,
		Result:       subs,
	}
}

func getHostFromXFH(s string) (string, error) {
	if strings.Contains(s, ":") {
		realHost, _, err := net.SplitHostPort(s)
		if err != nil {
			return "", err
		}
		return realHost, nil
	}
	return s, nil
}
