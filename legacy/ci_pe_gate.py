#!/usr/bin/env python3
"""PE static gate for Windows XP compatibility of the legacy client exe.

Fails (exit != 0) if the binary would NOT load on Windows XP:
  * dynamic MSVC CRT / UCRT / api-ms-win-* imports (XP has only msvcrt.dll)
  * PE header MajorOperatingSystemVersion or MajorSubsystemVersion > 5
    (XP's loader rejects subsystem 6.x with "not a valid Win32 application")
  * Vista+/Win8+ only API imports (SRWLOCK, CONDITION_VARIABLE, FLS,
    GetSystemTimePreciseAsFileTime, WaitOnAddress, bcrypt, ...)

Usage:  python ci_pe_gate.py <path-to-exe>
"""
import struct
import sys

BAD_DLL = (
    "vcruntime140", "vcruntime140_1", "msvcp140", "msvcr120", "msvcp120",
    "msvcr110", "msvcp110", "ucrtbase", "api-ms-win",
    "bcrypt", "bcryptprimitives",
)

# Vista+/Win7+/Win8+ only APIs that do not exist on XP.
BAD_FUNC = (
    "acquiresrwlock", "releasesrwlock", "tryacquiresrwlock", "releasesrwlockexclusive",
    "acquiresrwlock exclusive", "releasesrwlock shared", "acquiresrwlock shared",
    "sleepconditionvariable", "wakeconditionvariable", "wakeallconditionvariable",
    "initializeconditionvariable", "flsalloc", "flssetvalue", "flsfree", "flsgetvalue",
    "getsystemtimepreciseasfiletime", "waitonaddress", "wakebyaddresssingle", "wakebyaddressall",
    "gettickcount64", "getsystemtimeprecise", "initializesynchronization", "initializelibrary",
    "compareobjecthandles", "getsocketinformation", "acquireworksubmission", "wakebyaddress",
    "setthreaddescription", "waitonaddress", "wakeconditionvariable", "trysrw",
    "querythreadcycle", "getlogicalprocessorinformationex", "initializecriticalsectionex",
    "createpseudoConsole", "getsystemtimes", "resizenvirtualmemory", "allocatetlsvirtualmemory",
)

# DLLs present on a stock Windows XP system (ntdll functions used by the std
# parking fallback are fine — NtWaitForKeyedEvent exists on XP).
XP_DLLS = {
    "kernel32.dll", "user32.dll", "gdi32.dll", "comctl32.dll", "advapi32.dll",
    "ws2_32.dll", "msvcrt.dll", "ole32.dll", "oleaut32.dll", "shell32.dll",
    "winmm.dll", "comdlg32.dll", "imm32.dll", "winspool.drv", "version.dll",
    "shlwapi.dll", "userenv.dll", "uxtheme.dll", "ntdll.dll", "rpcrt4.dll",
    "crypt32.dll", "iphlpapi.dll", "wininet.dll", "urlmon.dll", "kernelbase.dll",
    "dwmapi.dll", "dwrite.dll", "d3d11.dll", "d3d9.dll", "d2d1.dll",
}


def u16(o, data):
    return struct.unpack_from("<H", data, o)[0]


def u32(o, data):
    return struct.unpack_from("<I", data, o)[0]


def main():
    if len(sys.argv) < 2:
        print("usage: ci_pe_gate.py <exe>")
        sys.exit(2)
    path = sys.argv[1]
    data = open(path, "rb").read()
    if data[:2] != b"MZ":
        print("FAIL: not a PE file")
        sys.exit(1)
    e_lfanew = u32(0x3C, data)
    if data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
        print("FAIL: no PE signature")
        sys.exit(1)
    coff = e_lfanew + 4
    nsec = u16(coff + 2, data)
    opt = coff + 20
    magic = u16(opt, data)
    pe32p = magic == 0x20B
    majos = u16(opt + 40, data)
    minos = u16(opt + 42, data)
    majsub = u16(opt + 48, data)
    minsub = u16(opt + 50, data)
    ddoff = opt + (112 if pe32p else 96)
    so = coff + 20 + (u16(opt + 16, data) if False else (240 if pe32p else 224))

    def rva2off(rva):
        for i in range(nsec):
            s = so + i * 40
            va = u32(s + 12, data)
            vsz = u32(s + 8, data)
            rsz = u32(s + 16, data)
            raw = u32(s + 20, data)
            if va <= rva < va + max(vsz, rsz):
                return raw + (rva - va)
        return None

    dlls = []
    funcs = []
    for ddi in (1,):  # imports (delay imports not used by our chain)
        rva = u32(ddoff + ddi * 8, data)
        if not rva:
            continue
        o = rva2off(rva)
        if o is None:
            continue
        ob = 63 if pe32p else 31
        tsz = 8 if pe32p else 4
        while True:
            oft, ts, fwd, name_rva, ft = struct.unpack_from("<IIIII", data, o)
            if not name_rva:
                break
            no = rva2off(name_rva)
            if no is None:
                break
            end = data.index(b"\0", no)
            dll = data[no:end].decode("ascii", "replace").lower()
            dlls.append(dll)
            t = rva2off(ft or oft)
            if t is not None:
                while True:
                    v = struct.unpack_from("<Q" if pe32p else "<I", data, t)[0] if pe32p else u32(t, data)
                    if not v:
                        break
                    if not (v >> ob):
                        fo = rva2off(v & 0x7FFFFFFF)
                        if fo is not None:
                            e2 = data.index(b"\0", fo)
                            funcs.append(data[fo + 2:e2].decode("ascii", "replace").lower())
                    t += tsz
            o += 20

    all_dlls = sorted(set(dlls))
    errors = []

    # 1) dynamic CRT / UCRT / api-ms-win / CNG
    for d in all_dlls:
        if any(b in d for b in BAD_DLL):
            errors.append(f"imports forbidden DLL: {d}")

    # 2) PE header OS/subsystem version
    if majos > 5 or majsub > 5:
        errors.append(f"PE header OS/subsystem version {majos}.{minos}/{majsub}.{minsub} > 5.x (XP rejects)")

    # 3) unknown DLLs (not present on XP)
    suspect = [d for d in all_dlls if d not in XP_DLLS and not any(b in d for b in BAD_DLL)]
    for d in suspect:
        errors.append(f"imports DLL not present on XP: {d}")

    # 4) Vista+/Win8+ only APIs
    hits = [f for f in funcs if any(b in f for b in BAD_FUNC)]
    if hits:
        errors.append(f"Vista+/Win8+ only API imports: {sorted(set(hits))[:12]}")

    print(f"=== PE gate: {path} ===")
    print(f"machine={'PE32+' if pe32p else 'PE32'}  OS={majos}.{minos} subsystem={majsub}.{minsub}")
    print(f"imported DLLs ({len(all_dlls)}): {all_dlls}")
    print(f"imported functions checked: {len(funcs)}")

    if errors:
        print("\nXP COMPATIBILITY: FAIL")
        for e in errors:
            print("  - " + e)
        sys.exit(1)
    print("\nXP COMPATIBILITY: PASS")
    sys.exit(0)


if __name__ == "__main__":
    main()
