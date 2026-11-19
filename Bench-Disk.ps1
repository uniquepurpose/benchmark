<#
.SYNOPSIS
    Self-contained disk benchmark (IOPS, throughput, latency, burst) for a Windows drive.

.DESCRIPTION
    Benchmarks a test file on the target drive (default C:) with unbuffered I/O when
    running elevated, so results reflect the disk rather than the OS file cache.

    Workloads (each run -Runs times for -Seconds seconds):
      - Random 4K read, queue depth 1 (latency / random-seek measurement)
      - Random 4K read, write and mixed 70%R/30%W at queue depth -RandomQD
      - Sequential 1M read, write and mixed 70%R/30%W at queue depth -SeqQD

    For every workload it reports min/avg/max IOPS and MB/s across runs, per-I/O
    latency stats (min/avg/p50/p95/p99/max ms), and per-second burst IOPS.

.VERSION
    1.0 - Initial release
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Bench-Disk.ps1 -Drive C: -FileSizeGB 8 -Runs 3 -Seconds 10
#>
[CmdletBinding()]
param(
    [string]$Drive = "C:",
    [long]$FileSizeGB = 8,
    [int]$Runs = 3,
    [int]$Seconds = 10,
    [int]$RandomQD = 32,
    [int]$SeqQD = 8,
    [int]$MixedWritePercent = 30,
    [string]$CsvPath = "",
    [switch]$KeepTestFile
)

$ErrorActionPreference = 'Stop'

if ($Runs -lt 1)      { throw "Runs must be >= 1" }
if ($Seconds -lt 3)   { throw "Seconds must be >= 3" }
if ($FileSizeGB -lt 1) { throw "FileSizeGB must be >= 1" }

$driveName = $Drive.TrimEnd(':', '\', '/')
$root      = $driveName + ':\'
$testFile  = Join-Path $root 'Bench-Disk.tmp'
$fileSize  = $FileSizeGB * 1GB

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$psDrive = Get-PSDrive -Name $driveName -ErrorAction Stop
if ($psDrive.Free -lt ($fileSize + 1GB)) {
    throw ("Not enough free space on {0}: need {1:N0} GB free, have {2:N0} GB" -f $driveName, ($fileSize + 1GB)/1GB, $psDrive.Free/1GB)
}

if (-not $isAdmin) {
    Write-Warning "Not running elevated: unbuffered I/O unavailable, reads will partly hit the OS cache. Run as Administrator for true disk numbers."
}

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public class BenchResult
{
    public string Workload;
    public int BlockSize;
    public string Mode;
    public int QD;
    public double IopsMin, IopsMax, IopsAvg;
    public double MBpsMin, MBpsMax, MBpsAvg;
    public double LatAvg, LatP50, LatP95, LatP99, LatMin, LatMax;
    public double BurstMin, BurstMax;
    public long[] PerSecond;
}

public static class DiskBench
{
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 0x00000001;
    const uint FILE_SHARE_WRITE = 0x00000002;
    const uint CREATE_ALWAYS = 2;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
    const uint FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000;
    const uint FILE_FLAG_RANDOM_ACCESS = 0x10000000;
    const uint MEM_COMMIT = 0x1000;
    const uint MEM_RESERVE = 0x2000;
    const uint MEM_RELEASE = 0x8000;
    const uint PAGE_READWRITE = 0x04;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle hFile, IntPtr lpBuffer, uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle hFile, IntPtr lpBuffer, uint nNumberOfBytesToWrite, out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle hFile, long liDistanceToMove, out long lpNewFilePointer, uint dwMoveMethod);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetEndOfFile(SafeFileHandle hFile);

    [DllImport("kernel32.dll")]
    static extern IntPtr VirtualAlloc(IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);

    [DllImport("kernel32.dll")]
    static extern bool VirtualFree(IntPtr lpAddress, UIntPtr dwSize, uint dwFreeType);

    class Cfg
    {
        public string Name; public int Block; public bool Random; public string Mode; public int QD;
    }

    class RunOut
    {
        public long Ops;
        public long Bytes;
        public double ElapsedSec;
        public List<double> Lats = new List<double>();
        public Exception Error;
        public long[] PerSecond;
    }

    static IntPtr AllocBuf(int size)
    {
        IntPtr p = VirtualAlloc(IntPtr.Zero, (UIntPtr)size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (p == IntPtr.Zero) throw new Exception("VirtualAlloc failed");
        return p;
    }

    static SafeFileHandle OpenHandle(string path, bool write, bool random, bool unbuffered)
    {
        uint access = GENERIC_READ | (write ? GENERIC_WRITE : 0u);
        uint flags = random ? FILE_FLAG_RANDOM_ACCESS : FILE_FLAG_SEQUENTIAL_SCAN;
        if (unbuffered) flags |= FILE_FLAG_NO_BUFFERING;
        SafeFileHandle h = CreateFile(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
        if (h.IsInvalid && unbuffered)
        {
            flags &= ~FILE_FLAG_NO_BUFFERING;
            h = CreateFile(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
        }
        if (h.IsInvalid) throw new Exception("CreateFile failed, Win32 error " + Marshal.GetLastWin32Error());
        return h;
    }

    static RunOut RunOnce(string path, long fileSize, int blockSize, bool random, string mode, int writePercent, int qd, int seconds, bool unbuffered)
    {
        long blocks = fileSize / blockSize;
        var results = new RunOut[qd];
        var threads = new Thread[qd];
        var perSecond = new long[seconds + 2];
        var global = Stopwatch.StartNew();
        for (int t = 0; t < qd; t++)
        {
            int tid = t;
            results[tid] = new RunOut();
            threads[tid] = new Thread(delegate()
            {
                var rnd = new Random(1234567 + tid * 7919);
                var lats = results[tid].Lats;
                long ops = 0, bytes = 0;
                long seqPos = (long)tid * blockSize * 64;
                SafeFileHandle h = null;
                IntPtr buf = IntPtr.Zero;
                try
                {
                    h = OpenHandle(path, mode != "Read", random, unbuffered);
                    buf = AllocBuf(blockSize);
                    while (global.Elapsed.TotalSeconds < seconds)
                    {
                        long off;
                        if (random)
                            off = (long)(rnd.NextDouble() * blocks) * blockSize;
                        else
                        {
                            off = seqPos;
                            seqPos += blockSize;
                            if (seqPos + blockSize > fileSize) seqPos = (long)tid * blockSize;
                        }
                        bool doWrite = mode == "Write" || (mode == "Mixed" && rnd.Next(100) < writePercent);
                        long np;
                        SetFilePointerEx(h, off, out np, 0);
                        var sw = Stopwatch.StartNew();
                        uint done;
                        bool ok;
                        if (doWrite) ok = WriteFile(h, buf, (uint)blockSize, out done, IntPtr.Zero);
                        else         ok = ReadFile(h, buf, (uint)blockSize, out done, IntPtr.Zero);
                        sw.Stop();
                        if (!ok) break;
                        ops++;
                        bytes += blockSize;
                        lats.Add(sw.Elapsed.TotalMilliseconds);
                        int sec = (int)global.Elapsed.TotalSeconds;
                        if (sec >= 0 && sec < perSecond.Length) Interlocked.Increment(ref perSecond[sec]);
                    }
                    results[tid].Ops = ops;
                    results[tid].Bytes = bytes;
                }
                catch (Exception ex) { results[tid].Error = ex; }
                finally
                {
                    if (h != null) h.Dispose();
                    if (buf != IntPtr.Zero) VirtualFree(buf, UIntPtr.Zero, MEM_RELEASE);
                }
            });
            threads[tid].IsBackground = true;
        }
        for (int t = 0; t < qd; t++) threads[t].Start();
        for (int t = 0; t < qd; t++) threads[t].Join();
        global.Stop();

        var all = new RunOut();
        all.ElapsedSec = global.Elapsed.TotalSeconds;
        all.PerSecond = perSecond;
        var allLats = new List<double>();
        foreach (var r in results)
        {
            if (r.Error != null) throw new Exception("Worker failed: " + r.Error.Message, r.Error);
            all.Ops += r.Ops;
            all.Bytes += r.Bytes;
            allLats.AddRange(r.Lats);
        }
        all.Lats = allLats;
        return all;
    }

    static double Pct(List<double> sorted, double p)
    {
        if (sorted.Count == 0) return 0;
        int i = (int)Math.Ceiling(p / 100.0 * sorted.Count) - 1;
        if (i < 0) i = 0;
        if (i >= sorted.Count) i = sorted.Count - 1;
        return sorted[i];
    }

    public static List<BenchResult> RunAll(string path, long fileSize, int runs, int seconds, int randomQD, int seqQD, bool unbuffered, int mixedWritePercent)
    {
        using (var h = CreateFile(path, GENERIC_READ | GENERIC_WRITE, 0, IntPtr.Zero, CREATE_ALWAYS, FILE_FLAG_SEQUENTIAL_SCAN, IntPtr.Zero))
        {
            if (h.IsInvalid) throw new Exception("Cannot create test file, Win32 error " + Marshal.GetLastWin32Error());
            long np;
            SetFilePointerEx(h, fileSize, out np, 0);
            if (!SetEndOfFile(h)) throw new Exception("SetEndOfFile failed, Win32 error " + Marshal.GetLastWin32Error());
        }

        Console.WriteLine("Warming up (2s sequential read)...");
        RunOnce(path, fileSize, 1048576, false, "Read", 0, seqQD, 2, unbuffered);

        var configs = new List<Cfg>
        {
            new Cfg { Name = "Random 4K Read QD1",          Block = 4096,    Random = true,  Mode = "Read",  QD = 1 },
            new Cfg { Name = "Random 4K Read",              Block = 4096,    Random = true,  Mode = "Read",  QD = randomQD },
            new Cfg { Name = "Random 4K Write",             Block = 4096,    Random = true,  Mode = "Write", QD = randomQD },
            new Cfg { Name = "Random 4K Mixed 70R/30W",     Block = 4096,    Random = true,  Mode = "Mixed", QD = randomQD },
            new Cfg { Name = "Sequential 1M Read",          Block = 1048576, Random = false, Mode = "Read",  QD = seqQD },
            new Cfg { Name = "Sequential 1M Write",         Block = 1048576, Random = false, Mode = "Write", QD = seqQD },
            new Cfg { Name = "Sequential 1M Mixed 70R/30W", Block = 1048576, Random = false, Mode = "Mixed", QD = seqQD }
        };

        var results = new List<BenchResult>();
        foreach (var c in configs)
        {
            var iopsList = new List<double>();
            var mbpsList = new List<double>();
            var allLats = new List<double>();
            double burstMin = double.MaxValue, burstMax = 0;
            long[] lastPerSecond = null;
            for (int r = 0; r < runs; r++)
            {
                RunOut o = RunOnce(path, fileSize, c.Block, c.Random, c.Mode, mixedWritePercent, c.QD, seconds, unbuffered);
                double iops = o.Ops / o.ElapsedSec;
                double mbps = o.Bytes / o.ElapsedSec / 1048576.0;
                iopsList.Add(iops);
                mbpsList.Add(mbps);
                allLats.AddRange(o.Lats);
                lastPerSecond = o.PerSecond;
                for (int s = 1; s < seconds && s < o.PerSecond.Length; s++)
                {
                    if (o.PerSecond[s] > 0)
                    {
                        if (o.PerSecond[s] > burstMax) burstMax = o.PerSecond[s];
                        if (o.PerSecond[s] < burstMin) burstMin = o.PerSecond[s];
                    }
                }
                Console.WriteLine(string.Format("  {0} run {1}/{2}: {3:F0} IOPS, {4:F1} MB/s", c.Name, r + 1, runs, iops, mbps));
            }
            allLats.Sort();
            var br = new BenchResult();
            br.Workload = c.Name;
            br.BlockSize = c.Block;
            br.Mode = c.Mode;
            br.QD = c.QD;
            br.IopsMin = iopsList.Min(); br.IopsMax = iopsList.Max(); br.IopsAvg = iopsList.Average();
            br.MBpsMin = mbpsList.Min(); br.MBpsMax = mbpsList.Max(); br.MBpsAvg = mbpsList.Average();
            br.LatMin = allLats.Min(); br.LatMax = allLats.Max(); br.LatAvg = allLats.Average();
            br.LatP50 = Pct(allLats, 50); br.LatP95 = Pct(allLats, 95); br.LatP99 = Pct(allLats, 99);
            br.BurstMin = burstMin == double.MaxValue ? 0 : burstMin;
            br.BurstMax = burstMax;
            br.PerSecond = lastPerSecond;
            results.Add(br);
        }
        return results;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp

Write-Host ("Benchmarking {0}  test file: {1} ({2} GB)" -f $root, $testFile, $FileSizeGB)
Write-Host ("Runs: {0} x {1}s per workload, QD random={2}, sequential={3}, elevated={4}" -f $Runs, $Seconds, $RandomQD, $SeqQD, $isAdmin)
Write-Host ("Estimated duration: ~{0:N0} minutes" -f ((7 * $Runs * $Seconds + 2) / 60.0))

try {
    $results = [DiskBench]::RunAll($testFile, $fileSize, $Runs, $Seconds, $RandomQD, $SeqQD, $isAdmin, $MixedWritePercent)

    Write-Host ""
    Write-Host ("=== IOPS and throughput across {0} runs (min / avg / max) ===" -f $Runs)
    $results | Select-Object Workload, QD,
        @{N='IOPS min';E={[math]::Round($_.IopsMin,0)}},
        @{N='IOPS avg';E={[math]::Round($_.IopsAvg,0)}},
        @{N='IOPS max';E={[math]::Round($_.IopsMax,0)}},
        @{N='MB/s min';E={[math]::Round($_.MBpsMin,1)}},
        @{N='MB/s avg';E={[math]::Round($_.MBpsAvg,1)}},
        @{N='MB/s max';E={[math]::Round($_.MBpsMax,1)}} |
        Format-Table -AutoSize | Out-Host

    Write-Host "=== Per-I/O latency in ms (min / avg / p50 / p95 / p99 / max) ==="
    $results | Select-Object Workload, QD,
        @{N='min';E={[math]::Round($_.LatMin,3)}},
        @{N='avg';E={[math]::Round($_.LatAvg,3)}},
        @{N='p50';E={[math]::Round($_.LatP50,3)}},
        @{N='p95';E={[math]::Round($_.LatP95,3)}},
        @{N='p99';E={[math]::Round($_.LatP99,3)}},
        @{N='max';E={[math]::Round($_.LatMax,3)}} |
        Format-Table -AutoSize | Out-Host

    Write-Host "=== Burst profile (per-second IOPS within a run, min / max) ==="
    $results | Select-Object Workload, QD,
        @{N='burst min IOPS/s';E={[math]::Round($_.BurstMin,0)}},
        @{N='burst max IOPS/s';E={[math]::Round($_.BurstMax,0)}} |
        Format-Table -AutoSize | Out-Host

    $rr = $results | Where-Object { $_.Workload -like 'Random 4K Read*' -and $_.QD -eq $RandomQD } | Select-Object -First 1
    if ($rr -and $rr.PerSecond) {
        Write-Host ("Per-second IOPS of last '{0} QD{1}' run: {2}" -f $rr.Workload, $rr.QD, (($rr.PerSecond | Select-Object -Skip 1 -First $Seconds) -join ', '))
    }

    if ($CsvPath) {
        $results | Select-Object Workload, BlockSize, Mode, QD,
            @{N='IopsMin';E={[math]::Round($_.IopsMin,1)}},
            @{N='IopsAvg';E={[math]::Round($_.IopsAvg,1)}},
            @{N='IopsMax';E={[math]::Round($_.IopsMax,1)}},
            @{N='MBpsMin';E={[math]::Round($_.MBpsMin,2)}},
            @{N='MBpsAvg';E={[math]::Round($_.MBpsAvg,2)}},
            @{N='MBpsMax';E={[math]::Round($_.MBpsMax,2)}},
            @{N='LatMinMs';E={[math]::Round($_.LatMin,4)}},
            @{N='LatAvgMs';E={[math]::Round($_.LatAvg,4)}},
            @{N='LatP50Ms';E={[math]::Round($_.LatP50,4)}},
            @{N='LatP95Ms';E={[math]::Round($_.LatP95,4)}},
            @{N='LatP99Ms';E={[math]::Round($_.LatP99,4)}},
            @{N='LatMaxMs';E={[math]::Round($_.LatMax,4)}},
            @{N='BurstMinIops';E={[math]::Round($_.BurstMin,1)}},
            @{N='BurstMaxIops';E={[math]::Round($_.BurstMax,1)}} |
            Export-Csv -Path $CsvPath -NoTypeInformation
        Write-Host ("CSV written to {0}" -f $CsvPath)
    }
}
finally {
    if (-not $KeepTestFile -and (Test-Path $testFile)) {
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    }
}