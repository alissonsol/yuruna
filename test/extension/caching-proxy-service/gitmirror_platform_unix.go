//go:build !windows

// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"os"
	"os/exec"
	"syscall"
)

func mirrorPrepareProcess(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} }
func mirrorStopProcess(cmd *exec.Cmd, force bool) {
	if cmd.Process == nil {
		return
	}
	signal := syscall.SIGTERM
	if force {
		signal = syscall.SIGKILL
	}
	_ = syscall.Kill(-cmd.Process.Pid, signal)
}
func mirrorProcessGroupAlive(cmd *exec.Cmd) bool {
	return cmd.Process != nil && syscall.Kill(-cmd.Process.Pid, 0) == nil
}
func mirrorTryLock(file *os.File, exclusive bool) error {
	op := syscall.LOCK_SH
	if exclusive {
		op = syscall.LOCK_EX
	}
	return syscall.Flock(int(file.Fd()), op|syscall.LOCK_NB)
}
func mirrorUnlock(file *os.File) { _ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN) }
func mirrorFreeBytes(path string) (uint64, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0, err
	}
	return uint64(stat.Bavail) * uint64(stat.Bsize), nil
}
func mirrorAllocatedBytes(info os.FileInfo) uint64 {
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		return uint64(stat.Blocks) * 512
	}
	return uint64(info.Size())
}
func mirrorSyncDirectory(path string) error {
	d, err := os.Open(path)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
func mirrorInheritGroup(file *os.File, parent string) error {
	info, err := os.Stat(parent)
	if err != nil {
		return err
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		return file.Chown(-1, int(stat.Gid))
	}
	return nil
}
