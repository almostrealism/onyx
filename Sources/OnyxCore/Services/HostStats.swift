//
// HostStats.swift
//
// Responsibility: The scripts the monitor polls a host with — CPU, memory,
//                 GPU and docker in one, the accelerators in two more.
// Scope: Service. Strings; the parsing is MonitorManager's.
//

import Foundation

public enum HostStats {

    /// The stats collection script, fed to a remote TERMINAL (see below).
    public static var script: String {
        // The DOCKER section was added for the screensaver's per-container
        // moon ring. MonitorManager.parse silently ignores unknown
        // sections, so this change is invisible to the existing monitor
        // overlay; only CPUFleetPoller reads the docker output.
        // KEEP THIS SCRIPT SMALL. It is fed to an interactive shell over a
        // PTY (`-tt`), and a terminal's input queue is ~1KB in total on
        // macOS — not per line, in total. Overflow it and the remainder is
        // discarded by the kernel: the shell waits for the rest of a line
        // that never comes, emits nothing but its login banner, and the
        // poll dies at the watchdog with no error to show for it.
        //
        // Pacing (RemoteExec.writePaced) is necessary but NOT sufficient.
        // Measured on a real failing host: unpaced, a 2.2KB script
        // produced nothing at all; paced, the front of it ran (a CPU
        // reading arrived) and the tail was still lost — no MEM section,
        // and no `exit`, so the session hung until the watchdog. Keep
        // both: pace the writes AND keep the payload small.
        //
        // This script was 736 bytes and worked on every host for months.
        // Adding AMD GPU + NPU probing took it to 2.4KB and killed stats
        // on every Mac — which is why that probing now lives in
        // `acceleratorCommand`, sent only to hosts that can answer it.
        // AppStateTests holds the size line; treat it as a hard budget,
        // not a guideline.
        let statsScript = """
        echo "---OS---"; uname -s
        echo "---UPTIME---"; uptime
        echo "---CPU---"; CPU_OUT=$(top -bn1 2>/dev/null | head -5)
        if [ -n "$CPU_OUT" ]; then echo "$CPU_OUT"; else top -l1 -s0 2>/dev/null | head -10; fi
        echo "---MEM---"; MEM_OUT=$(free -m 2>/dev/null)
        if [ -n "$MEM_OUT" ]; then echo "$MEM_OUT"; else vm_stat 2>/dev/null; fi
        echo "---GPU---"; G=$(timeout 5 nvidia-smi --query-gpu=utilization.gpu,utilization.memory,temperature.gpu,name --format=csv,noheader 2>/dev/null)
        [ -n "$G" ] || G=$(ioreg -r -d 1 -c IOAccelerator 2>/dev/null | grep -o 'Utilization %"=[0-9]*' | head -1 | cut -d= -f2 | sed 's/^/AGX,/')
        [ -n "$G" ] && echo "$G" || echo "N/A"
        echo "---DOCKER---"; T=""; command -v timeout >/dev/null 2>&1 && T="timeout 6"
        $T docker stats --no-stream --format "{{.Name}}|{{.CPUPerc}}" 2>/dev/null || true
        """
        return statsScript
    }

    /// Which accelerator to ask about. They're separate calls because a
    /// remote terminal will only swallow about 1KB in one go, and the two
    /// probes together don't fit — see `script`'s size note.
    public enum AcceleratorProbe {
        case amdGPU
        case npu
    }

    /// Accelerator probing (AMD GPU via amdgpu sysfs, XDNA NPU via the
    /// accel class) as SEPARATE, smaller calls off the hot path.
    ///
    /// They ride their own channel on their own slower cadence, and are
    /// only ever sent to hosts that reported Linux — a Mac can't answer a
    /// line of this, so spending the stats script's tiny size budget on it
    /// there bought nothing and cost every Mac its stats.
    /// The accelerator probe for `probe`, fed to a remote terminal.
    public static func acceleratorScript(_ probe: AcceleratorProbe) -> String {
        let script: String
        switch probe {
        case .amdGPU:
            script = """
            D=/sys/class/drm; G=""
            for c in $(ls $D 2>/dev/null); do p=$D/$c/device; B=$(cat $p/gpu_busy_percent 2>/dev/null); [ "$B" -ge 0 ] 2>/dev/null || continue; U=$(cat $p/mem_info_vram_used 2>/dev/null); T=$(cat $p/mem_info_vram_total 2>/dev/null); M=N/A; [ "$T" -gt 0 ] 2>/dev/null && M=$(( U * 100 / T )); K=N/A; for w in $(ls $p/hwmon 2>/dev/null); do X=$(cat $p/hwmon/$w/temp1_input 2>/dev/null); [ "$X" -ge 0 ] 2>/dev/null && K=$(( X / 1000 )) && break; done; G="$B %, $M %, $K, AMD GPU"; break; done
            echo "---GPU---"; [ -n "$G" ] && echo "$G" || echo "N/A"
            """
        case .npu:
            script = """
            E=/sys/class/accel; P=""
            for n in $(ls $E 2>/dev/null); do a=$E/$n/device; N=$(cat $a/vbnv 2>/dev/null); [ -n "$N" ] || N=NPU; C=$(cat $a/power/control 2>/dev/null); S=$(cat $a/power/runtime_status 2>/dev/null); [ "$C" = on ] && S=unknown; [ -n "$S" ] || S=unknown; F=$(cat $a/fw_version 2>/dev/null); A=$(cat $a/power/runtime_active_time 2>/dev/null); [ "$A" -ge 0 ] 2>/dev/null || A=; P="$N|$S|$F|$A"; break; done
            echo "---NPU---"; [ -n "$P" ] && echo "$P" || echo "N/A"
            """
        }
        return script
    }
}
