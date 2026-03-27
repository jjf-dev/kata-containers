package client

import (
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestLogVsockPayloadWritesFile(t *testing.T) {
	assert := assert.New(t)

	_ = os.Remove(VSockTraceFilePath)
	t.Cleanup(func() {
		_ = os.Remove(VSockTraceFilePath)
	})

	logVsockPayload("send", VSockSocketScheme, "3:1024", []byte("ping"), nil)

	data, err := os.ReadFile(VSockTraceFilePath)
	assert.NoError(err)

	content := string(data)
	assert.True(strings.Contains(content, `"layer":"transport"`))
	assert.True(strings.Contains(content, `"direction":"send"`))
	assert.True(strings.Contains(content, `"target":"3:1024"`))
}
