package client

import (
	"errors"
	"net"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

type testConn struct{}

func (c *testConn) Read(_ []byte) (int, error)         { return 0, nil }
func (c *testConn) Write(b []byte) (int, error)        { return len(b), nil }
func (c *testConn) Close() error                       { return nil }
func (c *testConn) LocalAddr() net.Addr                { return nil }
func (c *testConn) RemoteAddr() net.Addr               { return nil }
func (c *testConn) SetDeadline(_ time.Time) error      { return nil }
func (c *testConn) SetReadDeadline(_ time.Time) error  { return nil }
func (c *testConn) SetWriteDeadline(_ time.Time) error { return nil }

func TestCommonDialerWaitsBeforeRetrying(t *testing.T) {
	oldRetryInterval := defaultDialRetryInterval
	defaultDialRetryInterval = 10 * time.Millisecond
	t.Cleanup(func() {
		defaultDialRetryInterval = oldRetryInterval
	})

	attempts := make([]time.Time, 0, 3)
	conn, err := commonDialer(100*time.Millisecond, func() (net.Conn, error) {
		attempts = append(attempts, time.Now())
		if len(attempts) < 3 {
			return nil, errors.New("not ready")
		}
		return &testConn{}, nil
	}, errors.New("timeout"))

	assert.NoError(t, err)
	assert.NotNil(t, conn)
	assert.Len(t, attempts, 3)
	assert.GreaterOrEqual(t, attempts[1].Sub(attempts[0]), 8*time.Millisecond)
	assert.GreaterOrEqual(t, attempts[2].Sub(attempts[1]), 8*time.Millisecond)
}

func TestCommonDialerTimeoutDoesNotBlockOnCancel(t *testing.T) {
	done := make(chan struct{})
	defer close(done)

	start := time.Now()
	conn, err := commonDialer(20*time.Millisecond, func() (net.Conn, error) {
		<-done
		return nil, errors.New("still blocked")
	}, errors.New("timeout"))

	assert.Nil(t, conn)
	assert.EqualError(t, err, "timeout")
	assert.Less(t, time.Since(start), 100*time.Millisecond)
}
