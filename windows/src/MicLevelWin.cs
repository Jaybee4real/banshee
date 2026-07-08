using System.Runtime.InteropServices;

namespace Banshell;

public class MicLevelWin : IDisposable
{
    private delegate void WaveInProc(IntPtr handle, uint message, IntPtr instance, IntPtr param1, IntPtr param2);

    [DllImport("winmm.dll")]
    private static extern int waveInOpen(out IntPtr handle, uint deviceId, byte[] format,
        WaveInProc callback, IntPtr instance, uint flags);

    [DllImport("winmm.dll")]
    private static extern int waveInPrepareHeader(IntPtr handle, IntPtr header, uint size);

    [DllImport("winmm.dll")]
    private static extern int waveInUnprepareHeader(IntPtr handle, IntPtr header, uint size);

    [DllImport("winmm.dll")]
    private static extern int waveInAddBuffer(IntPtr handle, IntPtr header, uint size);

    [DllImport("winmm.dll")]
    private static extern int waveInStart(IntPtr handle);

    [DllImport("winmm.dll")]
    private static extern int waveInStop(IntPtr handle);

    [DllImport("winmm.dll")]
    private static extern int waveInReset(IntPtr handle);

    [DllImport("winmm.dll")]
    private static extern int waveInClose(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)]
    private struct WaveHdr
    {
        public IntPtr Data;
        public uint BufferLength;
        public uint BytesRecorded;
        public IntPtr User;
        public uint Flags;
        public uint Loops;
        public IntPtr Next;
        public IntPtr Reserved;
    }

    private const uint CALLBACK_FUNCTION = 0x00030000;
    private const uint WIM_DATA = 0x3C0;
    private const uint WAVE_MAPPER = 0xFFFFFFFF;
    private const int SampleRate = 8000;
    private const int BufferSamples = 4096;

    private IntPtr handle;
    private readonly List<GCHandle> pinned = new();
    private readonly List<IntPtr> headers = new();
    private WaveInProc? proc;
    private float? baseline;
    private readonly List<double> baselineSamples = new();
    private int loudFrames;
    private bool running;

    public event Action? Loud;

    public void Start()
    {
        if (running) return;
        try
        {
            var format = BuildFormat();
            proc = OnWaveIn;
            if (waveInOpen(out handle, WAVE_MAPPER, format, proc, IntPtr.Zero, CALLBACK_FUNCTION) != 0) return;
            for (int index = 0; index < 2; index++) AddBuffer();
            waveInStart(handle);
            running = true;
        }
        catch
        {
            running = false;
        }
    }

    private static byte[] BuildFormat()
    {
        var format = new byte[18];
        BitConverter.GetBytes((ushort)1).CopyTo(format, 0);        // PCM
        BitConverter.GetBytes((ushort)1).CopyTo(format, 2);        // mono
        BitConverter.GetBytes((uint)SampleRate).CopyTo(format, 4);
        BitConverter.GetBytes((uint)(SampleRate * 2)).CopyTo(format, 8);
        BitConverter.GetBytes((ushort)2).CopyTo(format, 12);       // block align
        BitConverter.GetBytes((ushort)16).CopyTo(format, 14);      // bits
        BitConverter.GetBytes((ushort)0).CopyTo(format, 16);
        return format;
    }

    private void AddBuffer()
    {
        var buffer = new byte[BufferSamples * 2];
        var bufferHandle = GCHandle.Alloc(buffer, GCHandleType.Pinned);
        pinned.Add(bufferHandle);
        var header = new WaveHdr
        {
            Data = bufferHandle.AddrOfPinnedObject(),
            BufferLength = (uint)buffer.Length,
        };
        var headerPointer = Marshal.AllocHGlobal(Marshal.SizeOf<WaveHdr>());
        Marshal.StructureToPtr(header, headerPointer, false);
        headers.Add(headerPointer);
        waveInPrepareHeader(handle, headerPointer, (uint)Marshal.SizeOf<WaveHdr>());
        waveInAddBuffer(handle, headerPointer, (uint)Marshal.SizeOf<WaveHdr>());
    }

    private void OnWaveIn(IntPtr waveHandle, uint message, IntPtr instance, IntPtr param1, IntPtr param2)
    {
        if (message != WIM_DATA || !running) return;
        try
        {
            var header = Marshal.PtrToStructure<WaveHdr>(param1);
            int sampleCount = (int)(header.BytesRecorded / 2);
            if (sampleCount > 0)
            {
                double sumSquares = 0;
                for (int index = 0; index < sampleCount; index++)
                {
                    short sample = Marshal.ReadInt16(header.Data, index * 2);
                    double normalized = sample / 32768.0;
                    sumSquares += normalized * normalized;
                }
                double rms = Math.Sqrt(sumSquares / sampleCount);
                double decibels = 20 * Math.Log10(Math.Max(rms, 1e-7));
                Evaluate((float)decibels);
            }
            waveInAddBuffer(waveHandle, param1, (uint)Marshal.SizeOf<WaveHdr>());
        }
        catch { }
    }

    private void Evaluate(float decibels)
    {
        if (baselineSamples.Count < 40)
        {
            baselineSamples.Add(decibels);
            if (baselineSamples.Count == 40) baseline = (float)baselineSamples.Average();
            return;
        }
        if (baseline is not { } reference) return;
        if (decibels > reference + 12) loudFrames++;
        else loudFrames = 0;
        if (loudFrames >= 3)
        {
            loudFrames = 0;
            Loud?.Invoke();
        }
    }

    public void Dispose()
    {
        if (!running && handle == IntPtr.Zero) return;
        running = false;
        try
        {
            waveInStop(handle);
            waveInReset(handle);
            foreach (var headerPointer in headers)
            {
                waveInUnprepareHeader(handle, headerPointer, (uint)Marshal.SizeOf<WaveHdr>());
                Marshal.FreeHGlobal(headerPointer);
            }
            waveInClose(handle);
        }
        catch { }
        headers.Clear();
        foreach (var bufferHandle in pinned) if (bufferHandle.IsAllocated) bufferHandle.Free();
        pinned.Clear();
        handle = IntPtr.Zero;
        baseline = null;
        baselineSamples.Clear();
    }
}
