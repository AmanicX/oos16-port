package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMkdevEncoding(t *testing.T) {
	tests := []struct {
		name    string
		maj     uint32
		min     uint32
		wantErr bool
	}{
		{"standard_loop", 7, 0, false},
		{"standard_misc", 10, 237, false},
		{"high_major_511", 511, 1024, false},
		{"max_supported_major", 0xfffff, 0xfffff, false},
		{"overflow_major", 0x100000, 0, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			dev, err := mkdev(tc.maj, tc.min)
			if (err != nil) != tc.wantErr {
				t.Fatalf("mkdev(%d, %d) error = %v, wantErr %v", tc.maj, tc.min, err, tc.wantErr)
			}
			if !tc.wantErr {
				// Verify decoding matches Linux glibc macro
				decMaj := uint32((uint64(dev)>>8)&0xfff | ((uint64(dev) >> 32) & ^uint64(0xfff)))
				decMin := uint32((uint64(dev) & 0xff) | ((uint64(dev) >> 12) & ^uint64(0xff)))
				if decMaj != tc.maj || decMin != tc.min {
					t.Errorf("Decoded mismatch: got (%d, %d), expected (%d, %d)", decMaj, decMin, tc.maj, tc.min)
				}
			}
		})
	}
}

func TestParseSysfsDev(t *testing.T) {
	tests := []struct {
		input   string
		wantMaj uint32
		wantMin uint32
		wantErr bool
	}{
		{"10:237\n", 10, 237, false},
		{"  7:0  ", 7, 0, false},
		{"0:0", 0, 0, false},
		{"", 0, 0, true},
		{"invalid", 0, 0, true},
		{"10", 0, 0, true},
		{"10:237:99", 0, 0, true},
		{"-10:20", 0, 0, true},
		{"10:-20", 0, 0, true},
		{"abc:237", 0, 0, true},
		{"10:xyz", 0, 0, true},
		{"99999999999999999999:1", 0, 0, true},
		{"1048576:1", 0, 0, true}, // > 0xfffff
	}

	for _, tc := range tests {
		maj, min, err := parseSysfsDev(tc.input)
		if (err != nil) != tc.wantErr {
			t.Errorf("parseSysfsDev(%q) err = %v, wantErr %v", tc.input, err, tc.wantErr)
		}
		if !tc.wantErr && (maj != tc.wantMaj || min != tc.wantMin) {
			t.Errorf("parseSysfsDev(%q) = (%d, %d), want (%d, %d)", tc.input, maj, min, tc.wantMaj, tc.wantMin)
		}
	}
}

func TestValidateOrCreateLegacyNodeRefuseOverwrite(t *testing.T) {
	tmpDir := t.TempDir()
	existingFile := filepath.Join(tmpDir, "regular_file")
	if err := os.WriteFile(existingFile, []byte("important-data"), 0644); err != nil {
		t.Fatal(err)
	}

	// Attempting to create legacy node on top of an ordinary file must fail
	err := validateOrCreateLegacyNode(existingFile, 10, 237, true)
	if err == nil {
		t.Fatalf("Expected error when target is regular file, got nil")
	}

	// Verify original content was untouched
	content, _ := os.ReadFile(existingFile)
	if string(content) != "important-data" {
		t.Fatalf("Original file content was corrupted!")
	}
}

func TestSafeSymlinkRefuseOverwrite(t *testing.T) {
	tmpDir := t.TempDir()
	destFile := filepath.Join(tmpDir, "unrelated")
	if err := os.WriteFile(destFile, []byte("do-not-overwrite"), 0644); err != nil {
		t.Fatal(err)
	}

	// Source missing
	err := safeSymlink(filepath.Join(tmpDir, "nonexistent"), destFile)
	if err == nil {
		t.Fatalf("Expected error when source does not exist, got nil")
	}

	// Destination is ordinary file: must refuse to overwrite
	srcMock := filepath.Join(tmpDir, "src_mock")
	_ = os.WriteFile(srcMock, []byte("mock"), 0666)
	err = safeSymlink(srcMock, destFile)
	if err == nil {
		t.Fatalf("Expected error when destination is ordinary file, got nil")
	}
}
