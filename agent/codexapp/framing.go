package codexapp

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

const maxFrameSize = 8 << 20

func readFrame(r io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	size := binary.LittleEndian.Uint32(header[:])
	if size == 0 {
		return nil, errors.New("codex app bridge: empty frame")
	}
	if size > maxFrameSize {
		return nil, fmt.Errorf("codex app bridge: frame size %d exceeds %d byte limit", size, maxFrameSize)
	}
	payload := make([]byte, size)
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func writeFrame(w io.Writer, payload []byte) error {
	if len(payload) == 0 {
		return errors.New("codex app bridge: empty frame")
	}
	if len(payload) > maxFrameSize {
		return fmt.Errorf("codex app bridge: frame size %d exceeds %d byte limit", len(payload), maxFrameSize)
	}
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], uint32(len(payload)))
	if _, err := w.Write(header[:]); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}
