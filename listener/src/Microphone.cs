using System.Runtime.InteropServices;

namespace Listener;

/// <summary>
/// Records from a microphone through WASAPI, as 16 kHz mono samples: Windows converts from whatever the mic records.
/// Each packet goes to the callback as it's captured, on the microphone's own thread, and nothing is kept.
/// </summary>
public sealed class Microphone : IDisposable
{
    readonly ManualResetEvent _stop = new(false);
    readonly TaskCompletionSource _started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly TaskCompletionSource _stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly Thread _thread;

    Microphone(string deviceId, Action<float[]> onAudio)
    {
        _thread = new Thread(() => Capture(deviceId, onAudio)) { IsBackground = true, Name = "Microphone" };
        _thread.Start();
    }

    /// <summary>
    /// Starts recording. Throws <see cref="MicrophoneException"/> if there's no such microphone or Windows won't let the
    /// app use it.
    /// </summary>
    /// <param name="deviceId">The microphone's ID from <see cref="List"/>, or empty for the one Windows sound settings call "Default Device".</param>
    /// <param name="onAudio">Each packet of samples (about 10 ms) as it's captured, called on the microphone's thread.</param>
    public static async Task<Microphone> StartAsync(string deviceId, Action<float[]> onAudio)
    {
        var microphone = new Microphone(deviceId, onAudio);
        await microphone._started.Task;
        return microphone;
    }

    /// <summary>The microphones plugged in and turned on, by ID and the name Windows sound settings show.</summary>
    public static List<(string Id, string Name)> List()
    {
        var microphones = new List<(string, string)>();
        var enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(EnumeratorId)!)!;
        var devices = enumerator.EnumAudioEndpoints(CaptureFlow, ActiveDevices);
        try
        {
            for (var i = 0u; i < devices.GetCount(); i++)
            {
                var device = devices.Item(i);
                var properties = device.OpenPropertyStore(ReadOnly);
                var key = FriendlyName;
                properties.GetValue(ref key, out var name);
                microphones.Add((device.GetId(), name.Type == WideString ? Marshal.PtrToStringUni(name.Value) ?? "" : ""));
                PropVariantClear(ref name);
                Marshal.ReleaseComObject(properties);
                Marshal.ReleaseComObject(device);
            }
        }
        finally
        {
            Marshal.ReleaseComObject(devices);
            Marshal.ReleaseComObject(enumerator);
        }
        return microphones;
    }

    /// <summary>Completes when recording stops: when disposed, or with a <see cref="MicrophoneException"/> if the microphone goes away.</summary>
    public Task Stopped => _stopped.Task;

    /// <summary>Stops recording. The callback isn't called again after this returns.</summary>
    public void Dispose()
    {
        _stop.Set();
        _thread.Join();
        _stop.Dispose();
    }

    void Capture(string deviceId, Action<float[]> onAudio)
    {
        object? enumerator = null;
        IMMDevice? device = null;
        IAudioClient? client = null;
        IAudioCaptureClient? capture = null;
        using var packetReady = new AutoResetEvent(false);
        var started = false;
        try
        {
            enumerator = Activator.CreateInstance(Type.GetTypeFromCLSID(EnumeratorId)!)!;
            device = deviceId.Length == 0
                ? ((IMMDeviceEnumerator)enumerator).GetDefaultAudioEndpoint(CaptureFlow, ConsoleRole)
                : ((IMMDeviceEnumerator)enumerator).GetDevice(deviceId);
            var iid = typeof(IAudioClient).GUID;
            client = (IAudioClient)device.Activate(ref iid, ClsCtxAll, IntPtr.Zero);
            var format = new WaveFormat
            {
                FormatTag = FloatFormat,
                Channels = 1,
                SamplesPerSecond = Transcriber.SampleRate,
                AverageBytesPerSecond = Transcriber.SampleRate * sizeof(float),
                BlockAlign = sizeof(float),
                BitsPerSample = 8 * sizeof(float),
            };
            // Shared with other apps (a call can use the mic too), woken for each packet, and converted to 16 kHz mono by Windows.
            client.Initialize(Shared, EventCallback | AutoConvertPcm | DefaultQualityRateConversion, BufferDuration, 0, ref format, IntPtr.Zero);
            client.SetEventHandle(packetReady.SafeWaitHandle.DangerousGetHandle());
            iid = typeof(IAudioCaptureClient).GUID;
            capture = (IAudioCaptureClient)client.GetService(ref iid);
            client.Start();
            started = true;
            _started.SetResult();

            var wake = new WaitHandle[] { _stop, packetReady };
            while (WaitHandle.WaitAny(wake) == 1)
                while (capture.GetNextPacketSize() > 0)
                {
                    capture.GetBuffer(out var data, out var frames, out var flags, out _, out _);
                    var samples = new float[frames];
                    if ((flags & SilentPacket) == 0) Marshal.Copy(data, samples, 0, samples.Length);
                    capture.ReleaseBuffer(frames);
                    onAudio(samples);
                }
            client.Stop();
            _stopped.SetResult();
        }
        catch (Exception ex)
        {
            var problem = new MicrophoneException(ex.HResult switch
            {
                AccessDenied => "Windows isn't letting the app use the microphone. Turn on \"Let desktop apps access your microphone\" in Settings > Privacy & security > Microphone.",
                NotFound or DeviceInvalidated when !started && deviceId.Length > 0 =>
                    "The microphone picked in Settings (Standup tab) isn't connected. Plug it in, or pick another there.",
                NotFound => "There's no microphone. Plug one in, or turn it on in Settings > System > Sound.",
                DeviceInvalidated => "The microphone was unplugged or turned off.",
                _ => "The microphone couldn't be used: " + ex.Message,
            }, ex);
            if (started) _stopped.SetException(problem);
            else _started.SetException(problem);
        }
        finally
        {
            foreach (var com in new[] { capture, client, device, enumerator })
                if (com != null) Marshal.ReleaseComObject(com);
        }
    }

    // ---- WASAPI, the parts used here (mmdeviceapi.h, audioclient.h and propsys.h) ----

    static readonly Guid EnumeratorId = new("BCDE0395-E52F-467C-8E3D-C4579291692E");   // CLSID_MMDeviceEnumerator
    static readonly PropertyKey FriendlyName = new() { FormatId = new("A45C254E-DF1C-4EFD-8020-67D146A850E0"), PropertyId = 14 };   // PKEY_Device_FriendlyName
    const int CaptureFlow = 1;                  // eCapture
    const int ConsoleRole = 0;                  // eConsole
    const int ActiveDevices = 1;                // DEVICE_STATE_ACTIVE
    const int ReadOnly = 0;                     // STGM_READ
    const ushort WideString = 31;               // VT_LPWSTR
    const int ClsCtxAll = 0x17;                 // CLSCTX_ALL
    const int Shared = 0;                       // AUDCLNT_SHAREMODE_SHARED
    const uint EventCallback = 0x00040000;      // AUDCLNT_STREAMFLAGS_EVENTCALLBACK
    const uint AutoConvertPcm = 0x80000000;     // AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
    const uint DefaultQualityRateConversion = 0x08000000;   // AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
    const long BufferDuration = 2_000_000;      // 200 ms, in 100-nanosecond units
    const ushort FloatFormat = 3;               // WAVE_FORMAT_IEEE_FLOAT
    const uint SilentPacket = 0x2;              // AUDCLNT_BUFFERFLAGS_SILENT
    const int AccessDenied = unchecked((int)0x80070005);
    const int NotFound = unchecked((int)0x80070490);
    const int DeviceInvalidated = unchecked((int)0x88890004);   // AUDCLNT_E_DEVICE_INVALIDATED

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    struct WaveFormat
    {
        public ushort FormatTag;
        public ushort Channels;
        public int SamplesPerSecond;
        public int AverageBytesPerSecond;
        public ushort BlockAlign;
        public ushort BitsPerSample;
        public ushort ExtraSize;
    }

    struct PropertyKey
    {
        public Guid FormatId;
        public int PropertyId;
    }

    // PROPVARIANT: a type tag, then the value (here, a pointer to a string) in a union as wide as two pointers.
    [StructLayout(LayoutKind.Sequential)]
    struct PropVariant
    {
        public ushort Type;
        ushort _reserved1, _reserved2, _reserved3;
        public IntPtr Value;
        IntPtr _rest;
    }

    [DllImport("ole32.dll")]
    static extern int PropVariantClear(ref PropVariant value);

    // The methods in the order of the vtable; the ones not called are declared only to keep their place.
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        IMMDeviceCollection EnumAudioEndpoints(int dataFlow, int stateMask);
        IMMDevice GetDefaultAudioEndpoint(int dataFlow, int role);
        IMMDevice GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        uint GetCount();
        IMMDevice Item(uint index);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [return: MarshalAs(UnmanagedType.IUnknown)]
        object Activate(ref Guid iid, int clsCtx, IntPtr activationParams);
        IPropertyStore OpenPropertyStore(int access);
        [return: MarshalAs(UnmanagedType.LPWStr)]
        string GetId();
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        uint GetCount();
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        void Initialize(int shareMode, uint streamFlags, long bufferDuration, long periodicity, ref WaveFormat format, IntPtr sessionGuid);
        uint GetBufferSize();
        long GetStreamLatency();
        uint GetCurrentPadding();
        void IsFormatSupported(int shareMode, ref WaveFormat format, out IntPtr closestMatch);
        IntPtr GetMixFormat();
        void GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        void Start();
        void Stop();
        void Reset();
        void SetEventHandle(IntPtr eventHandle);
        [return: MarshalAs(UnmanagedType.IUnknown)]
        object GetService(ref Guid iid);
    }

    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient
    {
        void GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        void ReleaseBuffer(uint frames);
        uint GetNextPacketSize();
    }
}

public sealed class MicrophoneException(string message, Exception? inner = null) : Exception(message, inner);
