using Microsoft.AspNetCore.Mvc.Formatters;
using System.IO;
using System.Threading.Tasks;

namespace grava.Controllers
{
    /// <summary>
    /// Helper to enable passing text/plain for PUT method
    /// </summary>
    public class TextPlainInputFormatter : InputFormatter
    {
        private const string ContentType = "text/plain";

        public TextPlainInputFormatter()
        {
            SupportedMediaTypes.Add(ContentType);
        }

        public override async Task<InputFormatterResult> ReadRequestBodyAsync(InputFormatterContext context)
        {
            Microsoft.AspNetCore.Http.HttpRequest request = context.HttpContext.Request;
            using StreamReader reader = new StreamReader(request.Body);
            string content = await reader.ReadToEndAsync();
            return await InputFormatterResult.SuccessAsync(content);
        }

        public override bool CanRead(InputFormatterContext context)
        {
            string contentType = context.HttpContext.Request.ContentType;
            return contentType.StartsWith(ContentType);
        }
    }
}
