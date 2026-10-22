// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.

package main

import (
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"unsafe"
)

var mirrorKernel = syscall.NewLazyDLL("kernel32.dll")
var mirrorLockFile = mirrorKernel.NewProc("LockFileEx")
var mirrorUnlockFile = mirrorKernel.NewProc("UnlockFileEx")
var mirrorDiskSpace = mirrorKernel.NewProc("GetDiskFreeSpaceExW")

func mirrorPrepareProcess(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP, HideWindow: true}
}
func mirrorStopProcess(cmd *exec.Cmd, force bool) {
	if cmd.Process == nil {
		return
	}
	args := []string{"/PID", strconv.Itoa(cmd.Process.Pid), "/T"}
	if force {
		args = append(args, "/F")
	}
	kill := exec.Command("taskkill", args...)
	kill.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	_ = kill.Run()
}
func mirrorProcessGroupAlive(cmd *exec.Cmd) bool { return cmd.ProcessState == nil }
func mirrorTryLock(file *os.File, exclusive bool) error {
	flags := uintptr(1)
	if exclusive {
		flags |= 2
	}
	var overlapped syscall.Overlapped
	ok, _, err := mirrorLockFile.Call(file.Fd(), flags, 0, 1, 0, uintptr(unsafe.Pointer(&overlapped)))
	if ok == 0 {
		return err
	}
	return nil
}
func mirrorUnlock(file *os.File) {
	var overlapped syscall.Overlapped
	_, _, _ = mirrorUnlockFile.Call(file.Fd(), 0, 1, 0, uintptr(unsafe.Pointer(&overlapped)))
}
func mirrorFreeBytes(path string) (uint64, error) {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}
	var available uint64
	ok, _, err := mirrorDiskSpace.Call(uintptr(unsafe.Pointer(p)), uintptr(unsafe.Pointer(&available)), 0, 0)
	if ok == 0 {
		return 0, err
	}
	return available, nil
}
func mirrorAllocatedBytes(info os.FileInfo) uint64 { return uint64(info.Size()) }
func mirrorSyncDirectory(string) error             { return nil }
func mirrorInheritGroup(*os.File, string) error    { return nil }
