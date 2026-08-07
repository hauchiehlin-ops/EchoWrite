using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Threading.Tasks;

namespace EchoWrite
{
    static class Program
    {
        private static NotifyIcon? _trayIcon;
        private static bool _isRecording = false;
        private static bool _isNativeCoreLoaded = false;
        
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
        private static extern IntPtr echowrite_process_audio_file_with_context(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string audioPath,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string style,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string? contextBefore);

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr echowrite_format_only(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string text);

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern void echowrite_free_string(IntPtr ptr);

        // 0 = Whisper, 1 = Llm
        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int echowrite_is_model_ready(int kind);

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern void echowrite_start_model_download(int kind);

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern void echowrite_get_model_download_progress(
            int kind, out ulong downloaded, out ulong total, out int state);

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern void echowrite_set_model_profile(int profileId);

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int echowrite_get_model_profile();

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int echowrite_add_custom_vocabulary([MarshalAs(UnmanagedType.LPUTF8Str)] string phrase);

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr echowrite_get_custom_vocabulary();

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr echowrite_export_sync_data();

        [DllImport("echowrite_core.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int echowrite_import_sync_data([MarshalAs(UnmanagedType.LPUTF8Str)] string json);

        private const int ModelKindWhisper = 0;
        private const int ModelKindLlm = 1;
        private const int ModelStateReady = 3;
        private const int ModelStateFailed = 4;

        private static bool _modelsReady = false;
        private static System.Windows.Forms.Timer? _modelDownloadTimer;

        // Windows API: 用於模擬鍵盤輸入與全域快捷鍵
        [DllImport("user32.dll")]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll")]
        private static extern void SendInput(uint nInputs, ref INPUT pInputs, int cbSize);

        private static string _currentStyle = "casual";
        private static int _currentProfile = 0; // 0 = Turbo, 1 = Pro

        [STAThread]
        static void Main()
        {
            // 全域未攔截例外處理器，徹底防止應用程式瞬閃無提示崩潰
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                string msg = e.ExceptionObject?.ToString() ?? "未知未處理例外";
                MessageBox.Show($"EchoWrite 發生未預期錯誤：\n\n{msg}", "EchoWrite 系統錯誤", MessageBoxButtons.OK, MessageBoxIcon.Error);
            };

            Application.ThreadException += (s, e) =>
            {
                MessageBox.Show($"EchoWrite 執行緒異常：\n\n{e.Exception.Message}", "EchoWrite 錯誤", MessageBoxButtons.OK, MessageBoxIcon.Error);
            };

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            // 0. 配置原生地區庫動態解析器 (明確鎖定執行檔同級目錄之 DLL)
            SetupNativeDllResolver();

            // 1. 初始化本地 Rust 核心引擎。加入防禦性例外攔截
            try
            {
                int initResult = echowrite_initialize("", "");
                if (initResult != 0)
                {
                    MessageBox.Show(
                        "EchoWrite 本地 AI 核心初始化未完全就緒 (代碼: " + initResult + ")。\n應用程式將以安全模式啟動並準備模型下載。",
                        "EchoWrite 提示",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information
                    );
                }
                _isNativeCoreLoaded = true;
            }
            catch (DllNotFoundException ex)
            {
                MessageBox.Show(
                    "無法載入 EchoWrite 原生核心 (echowrite_core.dll)。\n\n" +
                    "可能原因：\n" +
                    "1. 缺少 Microsoft Visual C++ 2015-2022 可轉散發套件 (x64)。\n" +
                    "2. echowrite_core.dll 未放置於同一應用程式資料夾。\n\n" +
                    "詳細資訊：" + ex.Message,
                    "EchoWrite 啟動失敗",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
                return;
            }
            catch (BadImageFormatException ex)
            {
                MessageBox.Show(
                    "架構不相容錯誤 (32-bit / 64-bit 混用)：\n" + ex.Message,
                    "EchoWrite 架構錯誤",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
                return;
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "核心載入時發生未知異常：\n" + ex.Message,
                    "EchoWrite 異常",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
                return;
            }

            // 2. 建立系統托盤圖示與右鍵選單 (System Tray Icon & ContextMenu)
            _trayIcon = new NotifyIcon()
            {
                Icon = System.Drawing.SystemIcons.Application,
                Text = "EchoWrite - 準備中...",
                Visible = true
            };
            SetupTrayContextMenu();
            _trayIcon.Click += TrayIcon_Click;

            // 3. 註冊全域快捷鍵 (Alt + S)
            var form = new KeyHandlerForm();
            RegisterHotKey(form.Handle, 1, 0x0001, 0x53); // MOD_ALT = 0x0001, S = 0x53

            // 4. 初次安裝或更新後，引導使用者開啟 Windows 麥克風權限
            RunPermissionOnboardingForInstallOrUpdate();

            // 5. 確認模型是否就緒，缺少的話啟動背景下載並輪詢進度
            EnsureModelsReady();

            Application.Run(form);
        }

        private static void SetupNativeDllResolver()
        {
            try
            {
                NativeLibrary.SetDllImportResolver(typeof(Program).Assembly, (libraryName, assembly, searchPath) =>
                {
                    if (libraryName == "echowrite_core.dll" || libraryName == "echowrite_core")
                    {
                        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
                        string dllPath = Path.Combine(baseDir, "echowrite_core.dll");
                        if (File.Exists(dllPath))
                        {
                            if (NativeLibrary.TryLoad(dllPath, out IntPtr handle))
                            {
                                return handle;
                            }
                        }
                    }
                    return IntPtr.Zero;
                });
            }
            catch (Exception ex)
            {
                Console.WriteLine("NativeLibrary resolver setup info: " + ex.Message);
            }
        }

        private static void SetupTrayContextMenu()
        {
            if (_trayIcon == null) return;
            var menu = new ContextMenuStrip();

            var styleMenu = new ToolStripMenuItem("🎭 語意風格切換 (AI Tone)");
            AddStyleMenuItem(styleMenu, "⚡ 極簡口語模式 (預設)", "casual");
            AddStyleMenuItem(styleMenu, "🏛️ 專業公文模式", "formal");
            AddStyleMenuItem(styleMenu, "✉️ 商務 Email 模式", "email");
            AddStyleMenuItem(styleMenu, "🌐 中英雙語對照", "bilingual");
            AddStyleMenuItem(styleMenu, "📋 條列重點模式", "bullet");
            menu.Items.Add(styleMenu);

            var profileMenu = new ToolStripMenuItem("🚀 效能與模型調度");
            var turboItem = new ToolStripMenuItem("⚡ Turbo 極速模式 (~200ms)", null, (s, e) => SetProfile(0));
            var proItem = new ToolStripMenuItem("🧠 Pro 旗艦高精度模式", null, (s, e) => SetProfile(1));
            turboItem.Checked = (_currentProfile == 0);
            proItem.Checked = (_currentProfile == 1);
            profileMenu.DropDownItems.Add(turboItem);
            profileMenu.DropDownItems.Add(proItem);
            menu.Items.Add(profileMenu);

            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add("📖 簡易操作指南 (Alt+S)...", null, (s, e) => ShowQuickGuideDialog());
            menu.Items.Add("🔒 零雲端隱私權政策...", null, (s, e) => ShowPrivacyPolicyDialog());

            menu.Items.Add(new ToolStripSeparator());

            menu.Items.Add("🚪 結束 EchoWrite", null, (s, e) => {
                _trayIcon.Visible = false;
                Application.Exit();
            });

            _trayIcon.ContextMenuStrip = menu;
        }

        private static void AddStyleMenuItem(ToolStripMenuItem parent, string label, string styleKey)
        {
            var item = new ToolStripMenuItem(label, null, (s, e) =>
            {
                _currentStyle = styleKey;
                SetupTrayContextMenu(); // 更新勾選狀態
            });
            item.Checked = (_currentStyle == styleKey);
            parent.DropDownItems.Add(item);
        }

        private static void SetProfile(int profileId)
        {
            _currentProfile = profileId;
            if (_isNativeCoreLoaded)
            {
                try
                {
                    echowrite_set_model_profile(profileId);
                }
                catch { }
            }
            SetupTrayContextMenu();
            string name = profileId == 1 ? "Pro 旗艦高精度模式" : "Turbo 極速模式";
            _trayIcon?.ShowBalloonTip(2000, "EchoWrite 效能切換", $"已切換為：{name}", ToolTipIcon.Info);
        }

        private static void ShowQuickGuideDialog()
        {
            string guide = "【EchoWrite Windows 快速上手指南】\n\n" +
                           "1. 🎙️ 開始/停止輸入：\n" +
                           "   在任何軟體 (VS Code、Word、LINE、瀏覽器) 按下 [Alt + S] 開始說話，說完再次按下自動潤飾輸入。\n\n" +
                           "2. 🗣️ 語音編輯指令：\n" +
                           "   • 說「換行」或「下一行」➔ 插入換行符號\n" +
                           "   • 說「空兩行」➔ 插入空行分段\n" +
                           "   • 說「加個問號」➔ 插入全形問號\n\n" +
                           "3. 🎭 5 大風格切換：\n" +
                           "   在右下角托盤圖示點右鍵即可隨時切換極簡、公文、Email、雙語與條列模式。\n\n" +
                           "4. 🚀 效能檔位：\n" +
                           "   支援 Turbo 極速模式 (200ms) 與 Pro 旗艦高精度模式。";
            MessageBox.Show(guide, "EchoWrite 簡易操作指南", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private static void ShowPrivacyPolicyDialog()
        {
            string policy = "【EchoWrite 零雲端隱私權政策 (Zero-Cloud Privacy)】\n\n" +
                            "🛡️ 100% 晶片端離線推論：\n" +
                            "所有語音辨識 (ASR) 與語意重塑 (SLM) 完全在您的電腦硬體離線運算。\n\n" +
                            "🚫 零資料上傳與零網路依賴：\n" +
                            "錄音音訊與轉寫文字絕不會發送至任何雲端伺服器，斷網狀態依然完整運作。\n\n" +
                            "🔑 零按鍵記錄 (Zero Keylogging)：\n" +
                            "僅在您按下 [Alt + S] 錄音期間捕捉麥克風語音，絕無任何鍵盤側錄行為。\n\n" +
                            "💾 本地透明儲存：\n" +
                            "個人詞庫僅儲存於本機 ~/.echowrite 目錄。";
            MessageBox.Show(policy, "EchoWrite 隱私權政策", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private static void EnsureModelsReady()
        {
            if (!_isNativeCoreLoaded || _trayIcon == null) return;

            try
            {
                bool whisperReady = echowrite_is_model_ready(ModelKindWhisper) == 1;
                bool llmReady = echowrite_is_model_ready(ModelKindLlm) == 1;

                if (whisperReady && llmReady)
                {
                    _modelsReady = true;
                    _trayIcon.Text = "EchoWrite - 按 Alt + S 開始錄音";
                    return;
                }

                _modelsReady = false;
                _trayIcon.Text = "EchoWrite - 下載模型中...";
                if (!whisperReady) echowrite_start_model_download(ModelKindWhisper);
                if (!llmReady) echowrite_start_model_download(ModelKindLlm);

                _modelDownloadTimer = new System.Windows.Forms.Timer { Interval = 1000 };
                _modelDownloadTimer.Tick += (sender, e) =>
                {
                    try
                    {
                        echowrite_get_model_download_progress(ModelKindWhisper, out ulong wDown, out ulong wTotal, out int wState);
                        echowrite_get_model_download_progress(ModelKindLlm, out ulong lDown, out ulong lTotal, out int lState);

                        if (wState == ModelStateFailed || lState == ModelStateFailed)
                        {
                            _trayIcon.Text = "EchoWrite - 模型下載失敗";
                            _trayIcon.ShowBalloonTip(5000, "EchoWrite", "模型下載失敗，請檢查網路連線後重新啟動應用程式。", ToolTipIcon.Error);
                            _modelDownloadTimer?.Stop();
                            return;
                        }

                        if (wState == ModelStateReady && lState == ModelStateReady)
                        {
                            _modelsReady = true;
                            _trayIcon.Text = "EchoWrite - 按 Alt + S 開始錄音";
                            _modelDownloadTimer?.Stop();
                            return;
                        }

                        ulong downloaded = wDown + lDown;
                        ulong total = Math.Max(wTotal + lTotal, 1);
                        int percent = (int)(downloaded * 100 / total);
                        _trayIcon.Text = $"EchoWrite - 下載模型中... {percent}%";
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine("Progress timer error: " + ex.Message);
                    }
                };
                _modelDownloadTimer.Start();
            }
            catch (Exception ex)
            {
                Console.WriteLine("EnsureModelsReady error: " + ex.Message);
            }
        }

        private static void TrayIcon_Click(object? sender, EventArgs e)
        {
            if (e is MouseEventArgs me && me.Button == MouseButtons.Left)
            {
                ToggleRecording();
            }
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
            if (_trayIcon == null) return;

            if (!_modelsReady)
            {
                _trayIcon.ShowBalloonTip(3000, "EchoWrite", "模型仍在準備中，請稍候片刻再試一次。", ToolTipIcon.Info);
                return;
            }

            try
            {
                int result = echowrite_start_recording();
                if (result != 0)
                {
                    OpenWindowsMicrophoneSettings();
                    _trayIcon.ShowBalloonTip(3000, "EchoWrite 錄音錯誤", "無法啟動錄音，請確定麥克風裝置已連接，且已在 Windows 「隱私權設定」中核准麥克風權限。", ToolTipIcon.Error);
                    Console.WriteLine("Windows: Failed to start recording. Error code: " + result);
                    return;
                }
                _isRecording = true;
                _trayIcon.Text = "EchoWrite - 錄音中 (按 Alt + S 停止)...";
                Console.WriteLine("Windows: Recording started...");
            }
            catch (Exception ex)
            {
                _trayIcon.ShowBalloonTip(3000, "EchoWrite 錯誤", "呼叫錄音核心失敗: " + ex.Message, ToolTipIcon.Error);
            }
        }

        private static void StopAndInsertText()
        {
            _isRecording = false;
            if (_trayIcon != null)
            {
                _trayIcon.Text = "EchoWrite - 處理中...";
            }

            Task.Run(() =>
            {
                try
                {
                    // 呼叫 Rust FFI 進行本地 AI 轉寫與重組
                    IntPtr textPtr = echowrite_stop_recording_and_process(_currentStyle);
                    string? resultText = Marshal.PtrToStringUTF8(textPtr);

                    if (!string.IsNullOrEmpty(resultText))
                    {
                        // 模擬打字插入活動游標
                        SimulateTyping(resultText);
                    }

                    echowrite_free_string(textPtr);
                }
                catch (Exception ex)
                {
                    Console.WriteLine("Process error: " + ex.Message);
                }
                finally
                {
                    if (_trayIcon != null)
                    {
                        _trayIcon.Text = "EchoWrite - 按 Alt + S 開始錄音";
                    }
                }
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

        private static void RunPermissionOnboardingForInstallOrUpdate()
        {
            try
            {
                string appDataDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "EchoWrite"
                );
                Directory.CreateDirectory(appDataDir);

                string markerPath = Path.Combine(appDataDir, "last-permission-onboarding.txt");
                string currentVersion = Application.ProductVersion;
                string previousVersion = File.Exists(markerPath) ? File.ReadAllText(markerPath).Trim() : "";
                if (previousVersion == currentVersion)
                {
                    return;
                }

                File.WriteAllText(markerPath, currentVersion);
                OpenWindowsMicrophoneSettings();
                _trayIcon?.ShowBalloonTip(
                    6000,
                    "EchoWrite 權限設定",
                    "請在 Windows「麥克風」隱私權設定中允許桌面應用程式存取麥克風，完成後即可用 Alt + S 開始錄音。",
                    ToolTipIcon.Info
                );
            }
            catch (Exception ex)
            {
                Console.WriteLine("Windows: Permission onboarding failed: " + ex.Message);
            }
        }

        private static void OpenWindowsMicrophoneSettings()
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "ms-settings:privacy-microphone",
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                Console.WriteLine("Windows: Failed to open microphone settings: " + ex.Message);
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
