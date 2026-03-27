package client

import (
	"encoding/json"
	"os"
	"sync"
	"time"
)

const VSockTraceFilePath = "/tmp/kata-vsock-trace.log"

type TraceRecord struct {
	Time      string `json:"time"`
	Layer     string `json:"layer"`
	Direction string `json:"direction,omitempty"`
	Type      string `json:"type,omitempty"`
	Target    string `json:"target,omitempty"`
	Method    string `json:"method,omitempty"`
	Length    int    `json:"len,omitempty"`
	Data      string `json:"data,omitempty"`
	Hex       string `json:"hex,omitempty"`
	Error     string `json:"error,omitempty"`
}

var traceFileMu sync.Mutex

func WriteTraceRecord(record TraceRecord) {
	record.Time = time.Now().UTC().Format(time.RFC3339Nano)

	buf, err := json.Marshal(record)
	if err != nil {
		return
	}

	traceFileMu.Lock()
	defer traceFileMu.Unlock()

	f, err := os.OpenFile(VSockTraceFilePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer f.Close()

	_, _ = f.Write(append(buf, '\n'))
}
