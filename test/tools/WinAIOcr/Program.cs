// WinAIOcr - Windows AI OCR helper for Get-NewText module.
// Uses Microsoft.Windows.AI.Imaging.TextRecognizer (Windows App SDK 1.8+)
// for higher-quality OCR than the legacy Windows.Media.Ocr.OcrEngine.
//
// Usage: WinAIOcr.exe <image-path>
// Output: recognized text lines to stdout
// Exit codes: 0 = success, 1 = error (message on stderr), 2 = TextRecognizer not available

using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Graphics.Imaging;
using Microsoft.Windows.AI.Imaging;
using Microsoft.Windows.ApplicationModel.DynamicDependency;
using Windows.Graphics.Imaging;
using Windows.Storage;

class Program
{
    static async Task<int> Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: WinAIOcr.exe <image-path>");
            return 1;
        }

        string imagePath = Path.GetFullPath(args[0]);
        if (!File.Exists(imagePath))
        {
            Console.Error.WriteLine($"File not found: {imagePath}");
            return 1;
        }

        try
        {
            Bootstrap.Initialize(0x00010008);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Windows App SDK initialization failed: {ex.GetType().Name}: {ex.Message}");
            Console.Error.WriteLine("Is the Windows App SDK 1.8 runtime installed?");
            return 2;
        }

        try
        {
            var readyState = TextRecognizer.GetReadyState();
            if (readyState != Microsoft.Windows.AI.AIFeatureReadyState.Ready)
            {
                try
                {
                    await TextRecognizer.EnsureReadyAsync();
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"TextRecognizer could not be made ready: {ex.GetType().Name}: {ex.Message}");
                    Console.Error.WriteLine("Requirements: Windows 11 with Windows App SDK 1.8+ and compatible AI hardware.");
                    return 2;
                }

                readyState = TextRecognizer.GetReadyState();
                if (readyState != Microsoft.Windows.AI.AIFeatureReadyState.Ready)
                {
                    Console.Error.WriteLine($"TextRecognizer not ready (state: {readyState}).");
                    return 2;
                }
            }

            var file = await StorageFile.GetFileFromPathAsync(imagePath);
            using var stream = await file.OpenAsync(Windows.Storage.FileAccessMode.Read);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            var bitmap = await decoder.GetSoftwareBitmapAsync(
                BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);

            var imageBuffer = ImageBuffer.CreateForSoftwareBitmap(bitmap);

            using var recognizer = await TextRecognizer.CreateAsync();
            var result = recognizer.RecognizeTextFromImage(imageBuffer);

            var sb = new StringBuilder();
            foreach (var line in result.Lines)
            {
                sb.AppendLine(line.Text);
            }

            Console.Write(sb.ToString().TrimEnd());
            Bootstrap.Shutdown();
            return 0;
        }
        catch (UnauthorizedAccessException ex)
        {
            Console.Error.WriteLine($"TextRecognizer not available on this hardware: {ex.Message}");
            Console.Error.WriteLine("This feature requires a Copilot+ PC with NPU (40+ TOPS).");
            Bootstrap.Shutdown();
            return 2;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"OCR failed: {ex.GetType().Name}: {ex.Message}");
            Bootstrap.Shutdown();
            return 1;
        }
    }
}
