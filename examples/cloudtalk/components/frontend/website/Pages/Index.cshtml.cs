using Grava;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Logging;
using System.Text;
using website.Models;

namespace website.Pages
{
    [IgnoreAntiforgeryToken]
    public class IndexModel : PageModel
    {
        private readonly ILogger<IndexModel> _logger;
        private static readonly ReplicatedDictionary<string, string> _dictionary = new ReplicatedDictionary<string, string>();

        public KeyValue UserInput { get; set; }
        public string UserAction { get; set; }
        public string BackendUrl { get { return _dictionary.BackendUrl.ToString(); } }

        public IndexModel(ILogger<IndexModel> logger)
        {
            _logger = logger;
            _logger.LogDebug("IndexModel()");
            UserInput = new KeyValue();
        }

        public void OnGet()
        {
        }

        public void OnPostSet(KeyValue kv)
        {
            UserInput.Key = kv.Key;
            UserInput.Value = kv.Value;
            _dictionary.Set(kv.Key, kv.Value);

            UserAction = string.Format("Set for [{0},{1}] ", kv.Key, kv.Value);
        }

        public void OnPostGet(KeyValue kv)
        {
            UserInput.Key = kv.Key;
            UserInput.Value = string.Empty;
            if (!string.IsNullOrEmpty(UserInput.Key)) // Avoid getting the Keys making a call with the empty/null key
            {
                UserInput.Value = _dictionary.Get(kv.Key);
            }

            UserAction = string.Format("Get for [{0},{1}] ", kv.Key, kv.Value);
        }

        public void OnPostDelete(KeyValue kv)
        {
            UserInput.Key = kv.Key;
            UserInput.Value = _dictionary.Delete(kv.Key);

            UserAction = string.Format("Delete for [{0},{1}] ", kv.Key, kv.Value);
        }

        public void OnPostKeys(KeyValue kv)
        {
            UserInput.Key = kv.Key;
            UserInput.Value = kv.Value;

            StringBuilder sb = new StringBuilder();
            sb.Append(string.Format("Keys for [{0},{1}]<br />", kv.Key, kv.Value));
            sb.Append(_dictionary.GetKeys());
            UserAction = sb.ToString();
        }
    }
}
