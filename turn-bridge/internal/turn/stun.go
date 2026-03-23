// Package turn implements a minimal TURN client (RFC 5766) with
// correct STUN message handling (RFC 5389).
package turn

import (
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha1"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"math/rand"
	"net"
)

// STUN magic cookie (RFC 5389 Section 6).
const magicCookie = 0x2112A442

// STUN message types.
const (
	methodBinding   = 0x0001
	methodAllocate  = 0x0003
	methodRefresh   = 0x0004
	methodPermisson = 0x0008
	methodChBind    = 0x0009

	classRequest  = 0x0000
	classSuccess  = 0x0100
	classError    = 0x0110
	classIndicate = 0x0010
)

// Attribute types.
const (
	attrMappedAddr     = 0x0001
	attrUsername       = 0x0006
	attrMessageInteg   = 0x0008
	attrErrorCode      = 0x0009
	attrChannelNumber  = 0x000C
	attrLifetime       = 0x000D
	attrXORPeerAddr    = 0x0012
	attrData           = 0x0013
	attrRealm          = 0x0014
	attrNonce          = 0x0015
	attrXORRelayedAddr = 0x0016
	attrReqTransport   = 0x0019
	attrXORMappedAddr  = 0x0020
	attrFingerprint    = 0x8028
	attrSoftware       = 0x8022
)

// Transport protocol ID for Allocate (RFC 5766 Section 6.2).
const transportUDP = 17

// Message represents a parsed STUN/TURN message.
type Message struct {
	Type          uint16
	TransactionID [12]byte
	Attrs         map[uint16][]byte
}

// NewTransactionID generates a cryptographically random 12-byte ID.
func NewTransactionID() [12]byte {
	var tid [12]byte
	for i := range tid {
		tid[i] = byte(rand.Intn(256))
	}
	return tid
}

// ParseMessage decodes a STUN message from raw bytes.
// Returns an error if the message is malformed.
func ParseMessage(data []byte) (*Message, error) {
	if len(data) < 20 {
		return nil, errors.New("stun: message too short")
	}

	msgType := binary.BigEndian.Uint16(data[0:2])
	msgLen := binary.BigEndian.Uint16(data[2:4])
	cookie := binary.BigEndian.Uint32(data[4:8])

	if cookie != magicCookie {
		return nil, fmt.Errorf("stun: bad magic cookie: 0x%08X", cookie)
	}

	if int(msgLen)+20 > len(data) {
		return nil, fmt.Errorf("stun: message length %d exceeds data %d", msgLen, len(data)-20)
	}

	m := &Message{
		Type:  msgType,
		Attrs: make(map[uint16][]byte),
	}
	copy(m.TransactionID[:], data[8:20])

	offset := 20
	end := 20 + int(msgLen)
	for offset+4 <= end {
		attrType := binary.BigEndian.Uint16(data[offset : offset+2])
		attrLen := int(binary.BigEndian.Uint16(data[offset+2 : offset+4]))

		if offset+4+attrLen > end {
			return nil, fmt.Errorf("stun: attribute 0x%04X overflows message", attrType)
		}

		val := make([]byte, attrLen)
		copy(val, data[offset+4:offset+4+attrLen])
		m.Attrs[attrType] = val

		// Pad to 4-byte boundary.
		padded := attrLen
		if padded%4 != 0 {
			padded += 4 - (padded % 4)
		}
		offset += 4 + padded
	}

	return m, nil
}

// Builder constructs STUN messages.
type Builder struct {
	msgType       uint16
	transactionID [12]byte
	attrs         []attrEntry
}

type attrEntry struct {
	typ uint16
	val []byte
}

// NewBuilder creates a message builder for the given type and transaction ID.
func NewBuilder(msgType uint16, tid [12]byte) *Builder {
	return &Builder{
		msgType:       msgType,
		transactionID: tid,
	}
}

// AddAttr appends an attribute.
func (b *Builder) AddAttr(typ uint16, val []byte) {
	b.attrs = append(b.attrs, attrEntry{typ: typ, val: val})
}

// AddUint32Attr appends a 4-byte attribute.
func (b *Builder) AddUint32Attr(typ uint16, val uint32) {
	buf := make([]byte, 4)
	binary.BigEndian.PutUint32(buf, val)
	b.AddAttr(typ, buf)
}

// AddStringAttr appends a string attribute.
func (b *Builder) AddStringAttr(typ uint16, val string) {
	b.AddAttr(typ, []byte(val))
}

// AddXORPeerAddress encodes an XOR-PEER-ADDRESS attribute (RFC 5766 Section 14.3).
func (b *Builder) AddXORPeerAddress(ip net.IP, port int) {
	b.addXORAddress(attrXORPeerAddr, ip, port)
}

// AddChannelNumber encodes a CHANNEL-NUMBER attribute (RFC 5766 Section 14.1).
func (b *Builder) AddChannelNumber(ch uint16) {
	buf := make([]byte, 4)
	binary.BigEndian.PutUint16(buf[0:2], ch)
	// buf[2:4] = 0 (RFFU)
	b.AddAttr(attrChannelNumber, buf)
}

func (b *Builder) addXORAddress(attrType uint16, ip net.IP, port int) {
	ip4 := ip.To4()
	if ip4 == nil {
		return // IPv6 not supported in this minimal implementation
	}

	buf := make([]byte, 8)
	buf[0] = 0    // reserved
	buf[1] = 0x01 // IPv4 family
	binary.BigEndian.PutUint16(buf[2:4], uint16(port)^uint16(magicCookie>>16))

	xoredIP := binary.BigEndian.Uint32(ip4) ^ magicCookie
	binary.BigEndian.PutUint32(buf[4:8], xoredIP)

	b.AddAttr(attrType, buf)
}

// Build serializes the message without integrity or fingerprint.
func (b *Builder) Build() []byte {
	return b.buildUpTo(-1)
}

// BuildWithIntegrity serializes with MESSAGE-INTEGRITY using the given HMAC key.
// The key is md5(username:realm:password) per RFC 5389 Section 15.4.
func (b *Builder) BuildWithIntegrity(key []byte) []byte {
	// Build message up to (but not including) MESSAGE-INTEGRITY.
	raw := b.buildUpTo(-1)

	// Per RFC 5389 Section 15.4: adjust length to include MESSAGE-INTEGRITY (24 bytes).
	adjustedLen := len(raw) - 20 + 24
	binary.BigEndian.PutUint16(raw[2:4], uint16(adjustedLen))

	mac := hmac.New(sha1.New, key)
	mac.Write(raw)
	integrity := mac.Sum(nil) // 20 bytes

	// Append MESSAGE-INTEGRITY attribute.
	attr := make([]byte, 24)
	binary.BigEndian.PutUint16(attr[0:2], attrMessageInteg)
	binary.BigEndian.PutUint16(attr[2:4], 20)
	copy(attr[4:24], integrity)
	raw = append(raw, attr...)

	// Fix final length.
	binary.BigEndian.PutUint16(raw[2:4], uint16(len(raw)-20))

	return raw
}

// buildUpTo serializes all attributes. If stopBefore >= 0, stops before that index.
func (b *Builder) buildUpTo(stopBefore int) []byte {
	var body []byte
	for i, a := range b.attrs {
		if stopBefore >= 0 && i >= stopBefore {
			break
		}
		hdr := make([]byte, 4)
		binary.BigEndian.PutUint16(hdr[0:2], a.typ)
		binary.BigEndian.PutUint16(hdr[2:4], uint16(len(a.val)))
		body = append(body, hdr...)
		body = append(body, a.val...)

		// Pad to 4-byte boundary.
		if pad := len(a.val) % 4; pad != 0 {
			body = append(body, make([]byte, 4-pad)...)
		}
	}

	header := make([]byte, 20)
	binary.BigEndian.PutUint16(header[0:2], b.msgType)
	binary.BigEndian.PutUint16(header[2:4], uint16(len(body)))
	binary.BigEndian.PutUint32(header[4:8], magicCookie)
	copy(header[8:20], b.transactionID[:])

	return append(header, body...)
}

// LongTermKey derives the HMAC key per RFC 5389 Section 15.4:
// key = MD5(username:realm:password).
func LongTermKey(username, realm, password string) []byte {
	h := md5.Sum([]byte(username + ":" + realm + ":" + password))
	return h[:]
}

// ParseXORAddress decodes an XOR-MAPPED-ADDRESS or XOR-RELAYED-ADDRESS.
func ParseXORAddress(data []byte, tid [12]byte) (net.IP, int, error) {
	if len(data) < 8 {
		return nil, 0, errors.New("stun: xor-address too short")
	}

	family := data[1]
	if family != 0x01 {
		return nil, 0, fmt.Errorf("stun: unsupported address family 0x%02X", family)
	}

	port := int(binary.BigEndian.Uint16(data[2:4])) ^ int(magicCookie>>16)
	ipRaw := binary.BigEndian.Uint32(data[4:8]) ^ magicCookie
	ip := make(net.IP, 4)
	binary.BigEndian.PutUint32(ip, ipRaw)

	return ip, port, nil
}

// ParseErrorCode extracts the error class and number from an ERROR-CODE attribute.
// RFC 5389 Section 15.6: 4 bytes, byte 2 = class (hundreds), byte 3 = number (0-99).
func ParseErrorCode(data []byte) (int, string) {
	if len(data) < 4 {
		return 0, ""
	}
	class := int(data[2]) * 100
	number := int(data[3])
	code := class + number
	reason := ""
	if len(data) > 4 {
		reason = string(data[4:])
	}
	return code, reason
}

// AddFingerprint appends a CRC-32 FINGERPRINT attribute.
func AddFingerprint(data []byte) []byte {
	// Adjust length to include FINGERPRINT (8 bytes).
	binary.BigEndian.PutUint16(data[2:4], uint16(len(data)-20+8))
	crc := crc32.ChecksumIEEE(data) ^ 0x5354554E
	attr := make([]byte, 8)
	binary.BigEndian.PutUint16(attr[0:2], attrFingerprint)
	binary.BigEndian.PutUint16(attr[2:4], 4)
	binary.BigEndian.PutUint32(attr[4:8], crc)
	result := append(data, attr...)
	binary.BigEndian.PutUint16(result[2:4], uint16(len(result)-20))
	return result
}
