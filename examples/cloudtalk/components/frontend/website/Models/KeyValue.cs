using Microsoft.AspNetCore.Mvc;

namespace website.Models
{
    public class KeyValue
    {
        [BindProperty]
        public string Key { get; set; }

        [BindProperty]
        public string Value { get; set; }
    }
}
