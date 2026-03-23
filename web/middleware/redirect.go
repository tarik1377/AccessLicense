package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

// RedirectMiddleware returns a Gin middleware that handles URL redirections.
// It normalizes API path casing and blocks legacy /xui paths that could
// be used to fingerprint the panel.
func RedirectMiddleware(basePath string) gin.HandlerFunc {
	return func(c *gin.Context) {
		path := c.Request.URL.Path

		// Block legacy /xui paths — scanners probe these to identify x-ui panels.
		// Return 404 instead of redirecting (redirect would confirm panel identity).
		if strings.HasPrefix(path, basePath+"xui") {
			c.AbortWithStatus(http.StatusNotFound)
			return
		}

		// Normalize API path casing: /panel/API -> /panel/api
		from := basePath + "panel/API"
		to := basePath + "panel/api"
		if strings.HasPrefix(path, from) {
			newPath := to + path[len(from):]
			c.Redirect(http.StatusMovedPermanently, newPath)
			c.Abort()
			return
		}

		c.Next()
	}
}
