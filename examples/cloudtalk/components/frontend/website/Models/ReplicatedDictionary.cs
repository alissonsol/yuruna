using Microsoft.Extensions.Configuration;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Net.Http;

namespace Grava
{
    /// <summary>
    /// Replicated Dictionary
    /// </summary>
    public class ReplicatedDictionary<TKey, TValue> : Dictionary<TKey, TValue>
    {
        private static readonly HttpClient client = new HttpClient();
        public Uri BackendUrl = new Uri(string.Empty, UriKind.Relative);

        public ReplicatedDictionary() : base()
        {
            string baseUri = Environment.GetEnvironmentVariable("backendUrl");
            if (string.IsNullOrEmpty(baseUri))
            {
                Console.WriteLine("baseUri: null from environment");
                try
                {
                    baseUri = new ConfigurationBuilder().AddJsonFile("appsettings.json").Build().GetSection("grava")["backendUrl"];
                }
                catch { }
                if (string.IsNullOrEmpty(baseUri))
                {
                    Console.WriteLine("baseUri: null from appsettings.json");

                    baseUri = "http://grava:8088/api/KeyValue";
                }
            }
            Console.WriteLine(string.Format("baseUri: {0}", baseUri));
            BackendUrl = new Uri(baseUri);
        }

        public TValue Set(TKey key, TValue value)
        {
            client.DefaultRequestHeaders.Accept.Clear();

            string url = BackendUrl.AbsoluteUri + "/" + key;
            System.Console.WriteLine(string.Format("ReplicatedDictionary.Set[{0}] = {1} -> {2}", key, value, url));            

            HttpContent content = new StringContent(value as string);

            client.PutAsync(url, content);

            return value;
        }

        public TValue Get(TKey key)
        {
            client.DefaultRequestHeaders.Accept.Clear();

            string url = BackendUrl.AbsoluteUri + "/" + key;
            System.Console.WriteLine(string.Format("ReplicatedDictionary.Get[{0}] -> {1}", key, url));            

            HttpResponseMessage response = client.GetAsync(url).Result;

            TValue value = default;
            if (response.IsSuccessStatusCode)
            {
                try
                {
                    value = (TValue)(object)response.Content.ReadAsStringAsync().Result;
                }
                catch {};
            }

            return value;
        }

        public TValue Delete(TKey key)
        {
            client.DefaultRequestHeaders.Accept.Clear();

            string url = BackendUrl.AbsoluteUri + "/" + key;
            System.Console.WriteLine(string.Format("ReplicatedDictionary.Delete[{0}] -> {1}", key, url));            

            HttpResponseMessage response = client.DeleteAsync(url).Result;

            TValue value = default;
            if (response.IsSuccessStatusCode)
            {
                try
                {
                    value = (TValue)(object)response.Content.ReadAsStringAsync().Result;
                }
                catch { };
            }

            return value;
        }

        // TODO: public new Dictionary<TKey, TValue>.KeyCollection Keys
        public TKey GetKeys()
        {
            client.DefaultRequestHeaders.Accept.Clear();

            string url = BackendUrl.AbsoluteUri;
            System.Console.WriteLine(string.Format("ReplicatedDictionary.GetKeys() -> {0}", url));            

            HttpResponseMessage response = client.GetAsync(url).Result;

            TKey keys = default;
            if (response.IsSuccessStatusCode)
            {
                try
                {
                    keys = (TKey)(object)response.Content.ReadAsStringAsync().Result;
                }
                catch { };
            }

            return keys;
        }
    }
}
