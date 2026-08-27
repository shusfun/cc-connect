package codexapp

import (
	"bytes"
	"encoding/binary"
	"io"
	"testing"
)

type chunkReader struct {
	data []byte
	size int
}

func (r *chunkReader) Read(p []byte) (int, error) {
	if len(r.data) == 0 {
		return 0, io.EOF
	}
	n := r.size
	if n > len(r.data) {
		n = len(r.data)
	}
	if n > len(p) {
		n = len(p)
	}
	copy(p, r.data[:n])
	r.data = r.data[n:]
	return n, nil
}

func TestFrameRoundTripHandlesFragmentedAndStickyFrames(t *testing.T) {
	var stream bytes.Buffer
	if err := writeFrame(&stream, []byte(`{"first":true}`)); err != nil {
		t.Fatal(err)
	}
	if err := writeFrame(&stream, []byte(`{"second":true}`)); err != nil {
		t.Fatal(err)
	}
	reader := &chunkReader{data: stream.Bytes(), size: 3}
	first, err := readFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	second, err := readFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	if string(first) != `{"first":true}` || string(second) != `{"second":true}` {
		t.Fatalf("unexpected frames: %s %s", first, second)
	}
}

func TestReadFrameRejectsOversize(t *testing.T) {
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], maxFrameSize+1)
	if _, err := readFrame(bytes.NewReader(header[:])); err == nil {
		t.Fatal("expected oversize frame error")
	}
}

func TestWriteFrameRejectsOversize(t *testing.T) {
	if err := writeFrame(io.Discard, make([]byte, maxFrameSize+1)); err == nil {
		t.Fatal("expected oversize frame error")
	}
}
