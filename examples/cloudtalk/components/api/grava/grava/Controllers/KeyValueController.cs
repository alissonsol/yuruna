using grava.Models;
using Microsoft.AspNetCore.Mvc;
using System.Collections.Generic;
using System.Text;
using System;

namespace grava.Controllers
{
    [Route("api/[controller]")]
    [ApiController]
    public class KeyValueController : ControllerBase
    {
        private static readonly IDictionary<string, string> _dictionary = new RslDictionary<string, string>();
        private static bool isInitialized;

        public KeyValueController()
        {
            if (!isInitialized)
            {
                System.Console.WriteLine("-- KeyValueController()");
                System.Console.WriteLine(string.Format("dictionary: {0}", _dictionary.ToString()));
                isInitialized = true;
            }
        }
        
        // curl -X GET "{backendUrl}" -H  "accept: text/plain"
        [HttpGet]
        public string Get()
        {
            System.Console.WriteLine(string.Format("\n{0} - grava.Get[]", DateTime.Now.ToLongTimeString()));

            StringBuilder sb = new StringBuilder();
            foreach (string k in _dictionary.Keys)
            {
                sb.Append(string.Format("{0}\n", k));
            }

            return sb.ToString();
        }

        // curl -X GET "{backendUrl}/[key]" -H  "accept: text/plain"
        [HttpGet("{key}")]
        public string Get(string key)
        {
            System.Console.WriteLine(string.Format("\n{0} - grava.Get[{1}]", DateTime.Now.ToLongTimeString(), key));

            string value = string.Empty;
            if (_dictionary.ContainsKey(key))
            {
                value = _dictionary[key];
            }

            return value;
        }

        // curl -X PUT "{backendUrl}/[key]" -H  "accept: */*" -H  "Content-Type: text/plain" -d "[value]"
        [HttpPut("{key}")]
        [Consumes("text/plain")]
        public void Put(string key, [FromBody] string value)
        {
            System.Console.WriteLine(string.Format("\n{0} - grava.Put[{1}] = {2}", DateTime.Now.ToLongTimeString(), key, value));

            if (_dictionary.ContainsKey(key))
            {
                _dictionary[key] = value;
            }
            else
            {
                _dictionary.Add(key, value);
            }
        }

        // curl -X DELETE "{backendUrl}/[key]" -H  "accept: */*"
        [HttpDelete("{key}")]
        public string Delete(string key)
        {
            System.Console.WriteLine(string.Format("\n{0} - grava.Delete[{1}]", DateTime.Now.ToLongTimeString(), key));

            string value = string.Empty;
            if (_dictionary.ContainsKey(key))
            {
                value = _dictionary[key];
            }
            _dictionary.Remove(key);

            return value;
        }
    }
}
