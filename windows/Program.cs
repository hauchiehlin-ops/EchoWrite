using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Threading.Tasks;

namespace EchoWrite
{
    static class Program
    {
        private static NotifyIcon _trayIcon;
        private static bool _isRecording = false;
        
        // 匯入 Rust 核心庫 (DLL FFI)
        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int echowrite_initialize(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string whisperPath,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string llmPath);

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int echowrite_start_recording();

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr echowrite_stop_recording_and_process(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string style);

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern void echowrite_free_string(IntPtr ptr);

        // Windows API: 用於模擬鍵盤輸入與全域快捷鍵
        [DllImport("user32.dll")]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll")]
        private static extern void SendInput(uint nInputs, ref INPUT pInputs, int cbSize);

        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            // 1. 初始化本地 Rust 核心引擎
            string whisperModel = AppDomain.CurrentDomain.BaseDirectory + "models\\whisper-medium-q5.bin";
            string llmModel = AppDomain.CurrentDomain.BaseDirectory + "models\\qwen-2.5-7b-q4.gguf";
            int initResult = echowrite_initialize(whisperModel, llmModel);
            if (initResult != 0)
            {
                MessageBox.Show("EchoWrite 核心初始化失敗，請確認模型檔案是否存在。", "EchoWrite", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // 2. 建立系統托盤圖示 (System Tray Icon)
            _trayIcon = new NotifyIcon()
            {
                Icon = System.Drawing.SystemIcons.Application,
                Text = "EchoWrite - 按 Alt + S 開始錄音",
                Visible = true
            };
            _trayIcon.Click += TrayIcon_Click;

            // 3. 註冊全域快捷鍵 (Alt + S)
            var form = new KeyHandlerForm();
            RegisterHotKey(form.Handle, 1, 0x0001, 0x53); // MOD_ALT = 0x0001, S = 0x53

            Application.Run(form);
        }

        private static void TrayIcon_Click(object sender, EventArgs e)
        {
            ToggleRecording();
        }

        public static void ToggleRecording()
        {
            if (_isRecording)
            {
                StopAndInsertText();
            }
            else
            {
                StartRecording();
            }
        }

        private static void StartRecording()
        {
            int result = echowrite_start_recording();
            if (result != 0)
            {
                _trayIcon.ShowBalloonTip(3000, "EchoWrite 錄音錯誤", "無法啟動錄音，請確定麥克風裝置已連接，且已在 Windows 「隱私權設定」中核准麥克風權限。", ToolTipIcon.Error);
                Console.WriteLine("Windows: Failed to start recording. Error code: " + result);
                return;
            }
            _isRecording = true;
            _trayIcon.Text = "EchoWrite - 錄音中 (按 Alt + S 停止)...";
            Console.WriteLine("Windows: Recording started...");
        }

        private static void StopAndInsertText()
        {
            _isRecording = false;
            _trayIcon.Text = "EchoWrite - 處理中...";

            Task.Run(() =>
            {
                // 呼叫 Rust FFI 進行本地 AI 轉寫與重組
                IntPtr textPtr = echowrite_stop_recording_and_process("professional");
                string resultText = Marshal.PtrToStringUTF8(textPtr);

                if (!string.IsNullOrEmpty(resultText))
                {
                    // 模擬打字插入活動游標
                    SimulateTyping(resultText);
                }

                echowrite_free_string(textPtr);
                _trayIcon.Text = "EchoWrite - 按 Alt + S 開始錄音";
            });
        }

        private static void SimulateTyping(string text)
        {
            // 利用 Windows SendInput 函數將文字轉換為鍵盤 Unicode 輸入
            foreach (char c in text)
            {
                INPUT inputDown = new INPUT { type = 1 }; // INPUT_KEYBOARD
                inputDown.u.ki = new KEYBDINPUT
                {
                    wVk = 0,
                    wScan = c,
                    dwFlags = 0x0004, // KEYEVENTF_UNICODE
                    time = 0,
                    dwExtraInfo = IntPtr.Zero
                };
                
                INPUT inputUp = inputDown;
                inputUp.u.ki.dwFlags = 0x0004 | 0x0002; // KEYEVENTF_UNICODE | KEYEVENTF_KEYUP

                SendInput(1, ref inputDown, Marshal.SizeOf(typeof(INPUT)));
                SendInput(1, ref inputUp, Marshal.SizeOf(typeof(INPUT)));
            }
        }

        // 定義 Windows API 結構
        [StructLayout(LayoutKind.Sequential)]
        struct INPUT
        {
            public uint type;
            public InputUnion u;
        }

        [StructLayout(LayoutKind.Explicit)]
        struct InputUnion
        {
            [FieldOffset(0)] public KEYBDINPUT ki;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct KEYBDINPUT
        {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        // 用於攔截全域快捷鍵的隱藏 Form
        private class KeyHandlerForm : Form
        {
            public KeyHandlerForm()
            {
                ShowInTaskbar = false;
                WindowState = FormWindowState.Minimized;
                FormBorderStyle = FormBorderStyle.FixedToolWindow;
                Opacity = 0;
                Load += (_, _) => Hide();
            }

            protected override void WndProc(ref Message m)
            {
                if (m.Msg == 0x0312) // WM_HOTKEY
                {
                    Program.ToggleRecording();
                }
                base.WndProc(ref m);
            }
        }
    }
}
