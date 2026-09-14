//
//  JITChecker.swift
//  JITTestApp
//
//  Created by Magesh K on 15/09/26.
//  Copyright © 2026 JITTestApp. All rights reserved.
//

import Foundation
import Darwin
import MachO
import os

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

@_silgen_name("sys_icache_invalidate")
private func sys_icache_invalidate(_ start: UnsafeMutableRawPointer?, _ len: Int)

@_silgen_name("sys_dcache_flush")
private func sys_dcache_flush(_ start: UnsafeMutableRawPointer?, _ len: Int)

private typealias PthreadJitWriteProtectSupportedNP = @convention(c) () -> Int32
private typealias PthreadJitWriteProtectNP = @convention(c) (Int32) -> Void

private let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)

private func pthreadJitWriteProtectSupported() -> Bool {
    guard let sym = dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_supported_np") else {
        return false
    }
    let fn = unsafeBitCast(sym, to: PthreadJitWriteProtectSupportedNP.self)
    return fn() != 0
}

private func pthreadJitWriteProtect(_ enabled: Int32) {
    guard let sym = dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np") else {
        return
    }
    let fn = unsafeBitCast(sym, to: PthreadJitWriteProtectNP.self)
    fn(enabled)
}

private func isAddressExecutable(_ addr: vm_address_t) -> (isExec: Bool, prot: vm_prot_t, maxProt: vm_prot_t, kr: kern_return_t) {
    var outAddr = addr
    var outSize: vm_size_t = 0
    var info = vm_region_basic_info_64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_64>.size / 4)
    var objName: mach_port_t = 0
    let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            vm_region_64(mach_task_self_, &outAddr, &outSize, VM_REGION_BASIC_INFO_64, intPtr, &count, &objName)
        }
    }
    guard kr == KERN_SUCCESS else {
        return (false, 0, 0, kr)
    }
    let isExec = (info.protection & VM_PROT_EXECUTE) != 0
    return (isExec, info.protection, info.max_protection, kr)
}

public struct JITDiagnostics: Sendable, Equatable {
    public let isJITActive: Bool
    public let isCsDebugged: Bool
    public let csopsReturnCode: Int32
    public let mmapSuccess: Bool
    public let mprotectSuccess: Bool
    public let executionSuccess: Bool
    public let magicReturnValue: Int?
    public let processId: pid_t
    public let processName: String
    public let executionDurationMs: Double
    public let activeStrategy: String?
    public let errorMessage: String?
}

public struct JITChecker {
    private static let CS_OPS_STATUS: UInt32 = 0
    private static let CS_DEBUGGED: UInt32 = 0x10000000
    private static let logger = Logger(subsystem: "org.sidestore.JITTestApp", category: "JIT")

    public static func runDiagnostics() -> JITDiagnostics {
        let startTime = CFAbsoluteTimeGetCurrent()
        print("==================== JIT CHECK START ====================")

        let currentPid = getpid()
        let procName = ProcessInfo.processInfo.processName

        // 1. Check Kernel Code Signing Flags (CS_DEBUGGED)
        var csFlags: UInt32 = 0
        let csResult = csops(currentPid, CS_OPS_STATUS, &csFlags, MemoryLayout<UInt32>.size)
        let isDebugged = (csResult == 0) && ((csFlags & CS_DEBUGGED) != 0)
        print("CS_OPS: result=\(csResult), flags=0x\(String(csFlags, radix: 16, uppercase: true)), CS_DEBUGGED=\(isDebugged)")

        if !isDebugged {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            print("CS_DEBUGGED is false. Skipping memory execution strategies to prevent AMFI SIGKILL.")
            print("JIT CHECK FINISHED: passed=false, time=\(String(format: "%.2f", elapsed))ms")
            print("=========================================================")
            return JITDiagnostics(
                isJITActive: false,
                isCsDebugged: false,
                csopsReturnCode: csResult,
                mmapSuccess: false,
                mprotectSuccess: false,
                executionSuccess: false,
                magicReturnValue: nil,
                processId: currentPid,
                processName: procName,
                executionDurationMs: elapsed,
                activeStrategy: nil,
                errorMessage: "Process has CS_DEBUGGED=false. Enable JIT first via SideStore."
            )
        }

        let pageSize = vm_size_t(sysconf(_SC_PAGESIZE))
        let isAPRRSupported = pthreadJitWriteProtectSupported()
        typealias JITFunction = @convention(c) () -> Int
        var diagLogs: [String] = []

        // ARM64 Instructions:
        // MOV X0, #42 -> 0xD2800540
        // RET         -> 0xD65F03C0
        let instructions: [UInt32] = [0xD2800540, 0xD65F03C0]
        let codeBytes = instructions.count * MemoryLayout<UInt32>.size

        // -------------------------------------------------------------
        // STRATEGY 1: POSIX mmap + mprotect (Standard W^X JIT under LLDB)
        // -------------------------------------------------------------
        print("Testing Strategy 1: POSIX mmap RWX + mprotect flip...")
        let mmapMem = mmap(nil, Int(pageSize), PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0)
        if mmapMem != MAP_FAILED, let mem = mmapMem {
            let addr = vm_address_t(UInt(bitPattern: mem))

            // Write instructions while page is RW
            let ptr = mem.assumingMemoryBound(to: UInt32.self)
            ptr[0] = 0xD2800540
            ptr[1] = 0xD65F03C0
            sys_dcache_flush(mem, codeBytes)

            // Flip from RW to RX via mprotect (kernel allows because max_protection is 7)
            let mprotRet = mprotect(mem, Int(pageSize), PROT_READ | PROT_EXEC)
            sys_icache_invalidate(mem, codeBytes)

            let status = isAddressExecutable(addr)
            print("Strategy 1: mprotectRet=\(mprotRet), status=(exec=\(status.isExec), prot=\(status.prot), max=\(status.maxProt), kr=\(status.kr))")

            if mprotRet == 0 && status.isExec {
                let fn = unsafeBitCast(mem, to: JITFunction.self)
                let ret = fn()
                print("Strategy 1 executed successfully! Return value: \(ret)")
                munmap(mem, Int(pageSize))

                if ret == 42 {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                    print("JIT CHECK FINISHED: SUCCESS via Strategy 1 (POSIX mmap + mprotect)")
                    print("=========================================================")
                    return JITDiagnostics(
                        isJITActive: true,
                        isCsDebugged: isDebugged,
                        csopsReturnCode: csResult,
                        mmapSuccess: true,
                        mprotectSuccess: true,
                        executionSuccess: true,
                        magicReturnValue: ret,
                        processId: currentPid,
                        processName: procName,
                        executionDurationMs: elapsed,
                        activeStrategy: "POSIX mmap + mprotect (W^X)",
                        errorMessage: nil
                    )
                }
            } else {
                diagLogs.append("mmap+mprotect: ret=\(mprotRet), prot=\(status.prot), max=\(status.maxProt)")
            }
            munmap(mem, Int(pageSize))
        } else {
            let err = errno
            print("Strategy 1 mmap failed: errno=\(err) (\(String(cString: strerror(err))))")
            diagLogs.append("mmap failed (errno=\(err))")
        }

        // -------------------------------------------------------------
        // STRATEGY 2: Dual-Mapping via mmap RWX + vm_remap RX
        // -------------------------------------------------------------
        print("Testing Strategy 2: Dual-Mapping (mmap RW + vm_remap RX)...")
        let rwMem = mmap(nil, Int(pageSize), PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0)
        if rwMem != MAP_FAILED, let rwPtr = rwMem {
            defer { munmap(rwPtr, Int(pageSize)) }

            let rwAddr = vm_address_t(UInt(bitPattern: rwPtr))
            let u32Ptr = rwPtr.assumingMemoryBound(to: UInt32.self)
            u32Ptr[0] = 0xD2800540
            u32Ptr[1] = 0xD65F03C0
            sys_dcache_flush(rwPtr, codeBytes)

            var rxAddr: vm_address_t = 0
            var curProt: vm_prot_t = 0
            var maxProt: vm_prot_t = 0
            let krRemap = vm_remap(
                mach_task_self_,
                &rxAddr,
                pageSize,
                0,
                VM_FLAGS_ANYWHERE,
                mach_task_self_,
                rwAddr,
                0,
                &curProt,
                &maxProt,
                VM_INHERIT_NONE
            )

            if krRemap == KERN_SUCCESS && rxAddr != 0 {
                defer { vm_deallocate(mach_task_self_, rxAddr, pageSize) }

                let krProtect = vm_protect(mach_task_self_, rxAddr, pageSize, 0, VM_PROT_READ | VM_PROT_EXECUTE)
                let status = isAddressExecutable(rxAddr)
                print("Strategy 2 DualMap: remap=OK, krProtect=\(krProtect), status=(exec=\(status.isExec), prot=\(status.prot), max=\(status.maxProt), kr=\(status.kr))")

                sys_icache_invalidate(UnsafeMutableRawPointer(bitPattern: rxAddr), codeBytes)

                if krProtect == KERN_SUCCESS && status.isExec {
                    let fn = unsafeBitCast(rxAddr, to: JITFunction.self)
                    let ret = fn()
                    print("Strategy 2 executed successfully! Return value: \(ret)")

                    if ret == 42 {
                        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                        print("JIT CHECK FINISHED: SUCCESS via Strategy 2 (Dual-Mapping)")
                        print("=========================================================")
                        return JITDiagnostics(
                            isJITActive: true,
                            isCsDebugged: isDebugged,
                            csopsReturnCode: csResult,
                            mmapSuccess: true,
                            mprotectSuccess: true,
                            executionSuccess: true,
                            magicReturnValue: ret,
                            processId: currentPid,
                            processName: procName,
                            executionDurationMs: elapsed,
                            activeStrategy: "Dual-Mapping (mmap RW / vm_remap RX)",
                            errorMessage: nil
                        )
                    }
                } else {
                    diagLogs.append("DualMap: remap=OK, protect=\(krProtect), status=(exec=\(status.isExec), prot=\(status.prot), max=\(status.maxProt))")
                }
            } else {
                print("Strategy 2 remap failed: kr=\(krRemap)")
                diagLogs.append("DualMap: remap failed (kr=\(krRemap))")
            }
        } else {
            let err = errno
            print("Strategy 2 mmap failed: errno=\(err)")
            diagLogs.append("DualMap: mmap failed (errno=\(err))")
        }

        // -------------------------------------------------------------
        // STRATEGY 3: Mach VM Page Flipping
        // -------------------------------------------------------------
        print("Testing Strategy 3: Mach VM Page Flipping...")
        var machAddr: vm_address_t = 0
        let krMachAlloc = vm_allocate(mach_task_self_, &machAddr, pageSize, VM_FLAGS_ANYWHERE)
        if krMachAlloc == KERN_SUCCESS && machAddr != 0 {
            defer { vm_deallocate(mach_task_self_, machAddr, pageSize) }

            let ptr = UnsafeMutablePointer<UInt32>(bitPattern: machAddr)!
            ptr[0] = 0xD2800540
            ptr[1] = 0xD65F03C0
            sys_dcache_flush(UnsafeMutableRawPointer(ptr), codeBytes)

            let krCur = vm_protect(mach_task_self_, machAddr, pageSize, 0, VM_PROT_READ | VM_PROT_EXECUTE)
            let status = isAddressExecutable(machAddr)
            print("Strategy 3 MachVM: setCur=\(krCur), status=(exec=\(status.isExec), prot=\(status.prot), max=\(status.maxProt), kr=\(status.kr))")

            sys_icache_invalidate(UnsafeMutableRawPointer(bitPattern: machAddr), codeBytes)

            if krCur == KERN_SUCCESS && status.isExec {
                let fn = unsafeBitCast(machAddr, to: JITFunction.self)
                let ret = fn()
                print("Strategy 3 executed successfully! Return value: \(ret)")

                if ret == 42 {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                    print("JIT CHECK FINISHED: SUCCESS via Strategy 3 (Mach VM)")
                    print("=========================================================")
                    return JITDiagnostics(
                        isJITActive: true,
                        isCsDebugged: isDebugged,
                        csopsReturnCode: csResult,
                        mmapSuccess: true,
                        mprotectSuccess: true,
                        executionSuccess: true,
                        magicReturnValue: ret,
                        processId: currentPid,
                        processName: procName,
                        executionDurationMs: elapsed,
                        activeStrategy: "Mach VM (vm_protect RW -> RX)",
                        errorMessage: nil
                    )
                }
            } else {
                diagLogs.append("MachVM: setCur=\(krCur), status=(exec=\(status.isExec), prot=\(status.prot), max=\(status.maxProt))")
            }
        } else {
            diagLogs.append("MachVM: alloc failed (kr=\(krMachAlloc))")
        }

        // -------------------------------------------------------------
        // STRATEGY 4: APRR MAP_JIT (pthread_jit_write_protect_np)
        // -------------------------------------------------------------
        print("Testing Strategy 4: APRR MAP_JIT...")
        let mapJitFlag: Int32 = 0x0800
        let jitMem = mmap(nil, Int(pageSize), PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | mapJitFlag, -1, 0)
        let mapErrno = errno
        if jitMem != MAP_FAILED, let mem = jitMem {
            defer { munmap(mem, Int(pageSize)) }

            if isAPRRSupported {
                pthreadJitWriteProtect(0)
            }

            let ptr = mem.assumingMemoryBound(to: UInt32.self)
            ptr[0] = 0xD2800540
            ptr[1] = 0xD65F03C0

            if isAPRRSupported {
                pthreadJitWriteProtect(1)
            }

            sys_icache_invalidate(mem, codeBytes)
            let status = isAddressExecutable(vm_address_t(UInt(bitPattern: mem)))
            print("Strategy 4 MAP_JIT: status=(exec=\(status.isExec), prot=\(status.prot), max=\(status.maxProt), kr=\(status.kr))")

            if status.isExec {
                let fn = unsafeBitCast(mem, to: JITFunction.self)
                let ret = fn()
                print("Strategy 4 executed successfully! Return value: \(ret)")

                if ret == 42 {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                    print("JIT CHECK FINISHED: SUCCESS via Strategy 4 (APRR MAP_JIT)")
                    print("=========================================================")
                    return JITDiagnostics(
                        isJITActive: true,
                        isCsDebugged: isDebugged,
                        csopsReturnCode: csResult,
                        mmapSuccess: true,
                        mprotectSuccess: true,
                        executionSuccess: true,
                        magicReturnValue: ret,
                        processId: currentPid,
                        processName: procName,
                        executionDurationMs: elapsed,
                        activeStrategy: "APRR MAP_JIT (Hardware W^X)",
                        errorMessage: nil
                    )
                }
            } else {
                diagLogs.append("MAP_JIT: status=(exec=\(status.isExec), prot=\(status.prot), max=\(status.maxProt))")
            }
        } else {
            print("Strategy 4 MAP_JIT failed: errno=\(mapErrno) (\(String(cString: strerror(mapErrno))))")
            diagLogs.append("MAP_JIT: mmap failed (errno=\(mapErrno): \(String(cString: strerror(mapErrno))))")
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        print("JIT CHECK FINISHED: passed=false, time=\(String(format: "%.2f", elapsed))ms")
        print("=========================================================")

        return JITDiagnostics(
            isJITActive: false,
            isCsDebugged: isDebugged,
            csopsReturnCode: csResult,
            mmapSuccess: true,
            mprotectSuccess: false,
            executionSuccess: false,
            magicReturnValue: nil,
            processId: currentPid,
            processName: procName,
            executionDurationMs: elapsed,
            activeStrategy: nil,
            errorMessage: diagLogs.joined(separator: "\n")
        )
    }
}
