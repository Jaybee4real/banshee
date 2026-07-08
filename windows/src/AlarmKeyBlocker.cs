using System.Runtime.InteropServices;

namespace Banshell;

public class AlarmKeyBlocker : IDisposable
{
    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookExW(int hookId, HookProc callback, IntPtr module, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetModuleHandleW(string? moduleName);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int virtualKey);

    [StructLayout(LayoutKind.Sequential)]
    private struct KbdLlHookStruct
    {
        public uint VkCode;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;

    private const uint VK_TAB = 0x09;
    private const uint VK_ESCAPE = 0x1B;
    private const uint VK_LWIN = 0x5B;
    private const uint VK_RWIN = 0x5C;
    private const uint VK_F4 = 0x73;
    private const int VK_CONTROL = 0x11;
    private const int VK_SHIFT = 0x10;
    private const int VK_MENU = 0x12;

    private const uint LLKHF_ALTDOWN = 0x20;

    private IntPtr hook;
    private readonly HookProc proc;

    public AlarmKeyBlocker()
    {
        proc = OnKey;
    }

    public void Start()
    {
        if (hook == IntPtr.Zero)
            hook = SetWindowsHookExW(WH_KEYBOARD_LL, proc, GetModuleHandleW(null), 0);
    }

    private static bool IsDown(int virtualKey) => (GetAsyncKeyState(virtualKey) & 0x8000) != 0;

    private IntPtr OnKey(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN))
        {
            var data = Marshal.PtrToStructure<KbdLlHookStruct>(lParam);
            var key = data.VkCode;
            bool alt = (data.Flags & LLKHF_ALTDOWN) != 0 || IsDown(VK_MENU);
            bool ctrl = IsDown(VK_CONTROL);
            bool shift = IsDown(VK_SHIFT);

            bool block =
                key == VK_LWIN || key == VK_RWIN ||
                (alt && key == VK_TAB) ||
                (alt && key == VK_ESCAPE) ||
                (alt && key == VK_F4) ||
                (ctrl && key == VK_ESCAPE) ||
                (ctrl && shift && key == VK_ESCAPE);

            if (block) return 1;
        }
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    public void Dispose()
    {
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }
}
