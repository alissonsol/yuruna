// Based on: https://github.com/microsoft/Ironclad/blob/main/ironfleet/src/IronRSLClient/RSLClient.cs
using System;
using System.Collections;
using System.Collections.Generic;
using System.Net;
using System.Runtime.Serialization;
using IronfleetIoFramework;
using IronRSLClient;
using KVMessages;

namespace grava.Models
{
    /// <summary>
    /// Replicated State Library Dictionary
    /// </summary>
    public class RslDictionary<TKey,TVal> : IDictionary<TKey,TVal>
    {
        private Dictionary<TKey, TVal> dictionary;
        private RSLClient _rslClient;
        private string _prefix = "/grava/{0}";
        private bool _isConnected;
        private bool _isVerbose;

        public RslDictionary()
        {
            Console.WriteLine("-- RslDictionary()");

            EnsureConnected();

            dictionary = new Dictionary<TKey, TVal>();
        }

        public void CopyTo(Array array, int index)
        {
            ((ICollection) dictionary).CopyTo(array, index);
        }

        public object SyncRoot
        {
            get { return ((ICollection) dictionary).SyncRoot; }
        }

        public bool IsSynchronized
        {
            get { return ((ICollection) dictionary).IsSynchronized; }
        }

        public bool Contains(object key)
        {
            return ((IDictionary) dictionary).Contains(key);
        }

        public void Add(object key, object value)
        {
            ((IDictionary) dictionary).Add(key, value);
        }

        public void Remove(object key)
        {
            ((IDictionary) dictionary).Remove(key);
        }

        public object this[object key]
        {
            get { return dictionary[(TKey) key]; }
            set { dictionary[(TKey) key] = (TVal) value; }
        }

        public bool IsFixedSize
        {
            get { return ((IDictionary) dictionary).IsFixedSize; }
        }

        public void Add(TKey key, TVal value)
        {
            Console.WriteLine("-- RslDictionary.Add({0},{1})", key.ToString(), value.ToString());
            if (!EnsureConnected()) 
            {
                return;
            }

            string _key = string.Format(_prefix, key.ToString());
            string _value = value.ToString();

            KVRequest request = new KVSetRequest(_key, _value);
            byte[] requestBytes = request.Encode();
            byte[] replyBytes = _rslClient.SubmitRequest(requestBytes, _isVerbose);
            KVReply reply = KVReply.Decode(replyBytes, 0);
        }

        public void Clear()
        {
            dictionary.Clear();
        }

        public bool Contains(KeyValuePair<TKey, TVal> item)
        {
            TVal v;
            return (dictionary.TryGetValue(item.Key, out v) && v.Equals(item.Key));
        }

        public void CopyTo(KeyValuePair<TKey, TVal>[] array, int arrayIndex)
        {
            ((ICollection<KeyValuePair<TKey, TVal>>)dictionary)
                .CopyTo(array,arrayIndex);
        }

        public bool Remove(KeyValuePair<TKey, TVal> item)
        {
            if (Contains(item))
            {
                dictionary.Remove(item.Key);
                return true;
            }
            return false;
        }

        public bool ContainsKey(TKey key)
        {
            Console.Write("-- RslDictionary.ContainsKey({0}): ", key.ToString());
            if (!EnsureConnected()) 
            {
                return false;
            }

            string _key = string.Format(_prefix, key.ToString());
            KVRequest request = new KVGetRequest(_key);
            byte[] requestBytes = request.Encode();
            byte[] replyBytes = _rslClient.SubmitRequest(requestBytes, _isVerbose);
            KVReply reply = KVReply.Decode(replyBytes, 0);
            if (reply is KVGetFoundReply grf)
            {
                Console.WriteLine("true --");
                return true;
            }

            Console.WriteLine("false --");
            return false;
        }

        public bool ContainsValue(TVal value)
        {
            return dictionary.ContainsValue(value);
        }

        public void GetObjectData(SerializationInfo info, StreamingContext context)
        {
            dictionary.GetObjectData(info, context);
        }

        public void OnDeserialization(object sender)
        {
            dictionary.OnDeserialization(sender);
        }

        public bool Remove(TKey key)
        {
            Console.Write("-- RslDictionary.Remove({0}): ", key.ToString());
            if (!EnsureConnected()) 
            {
                return false;
            }

            bool found = this.ContainsKey(key);
            string _key = string.Format(_prefix, key.ToString());

            KVRequest request = new KVDeleteRequest(_key);
            byte[] requestBytes = request.Encode();
            byte[] replyBytes = _rslClient.SubmitRequest(requestBytes, _isVerbose);
            KVReply reply = KVReply.Decode(replyBytes, 0);

            return found;
        }

        public bool TryGetValue(TKey key, out TVal value)
        {
            return dictionary.TryGetValue(key, out value);
        }

        public IEqualityComparer<TKey> Comparer
        {
            get { return dictionary.Comparer; }
        }

        public int Count
        {
            get { return dictionary.Count; }
        }

        public bool IsReadOnly { get; private set; }

        public TVal this[TKey key]
        {
            get
            {
                Console.Write("-- RslDictionary[{0}]", key.ToString());

                if (!EnsureConnected()) 
                {
                    return GetValue<TVal>(null);
                }

                string _key = string.Format(_prefix, key.ToString());
                KVRequest request = new KVGetRequest(_key);
                byte[] requestBytes = request.Encode();
                byte[] replyBytes = _rslClient.SubmitRequest(requestBytes, _isVerbose);
                KVReply reply = KVReply.Decode(replyBytes, 0);
                if (reply is KVGetFoundReply grf)
                {
                    string _value = grf.Val;
                    Console.WriteLine(" get = {0}", _value);

                    return GetValue<TVal>(_value);
                }

                return GetValue<TVal>(null);
            }
            set
            {
                Console.WriteLine("-- RslDictionary[{0}] = {1}", key.ToString(), value.ToString());

                this.Add(key, value);
            }
        }

        public ICollection<TKey> Keys
        {
            // TODO: need to go to network to get values across machines
            get { return dictionary.Keys; }
        }

        public ICollection<TVal> Values
        {
            get { return dictionary.Values; }
        }

        public IEnumerator<KeyValuePair<TKey, TVal>> GetEnumerator()
        {
            return dictionary.GetEnumerator();
        }

        public void Add(KeyValuePair<TKey,TVal> item)
        {
            dictionary.Add(item.Key,item.Value);
        }

        IEnumerator IEnumerable.GetEnumerator()
        {
            return dictionary.GetEnumerator();
        }        

        private bool EnsureConnected()        
        {
            if (_isConnected)
            {
                return true;
            }

            _isVerbose = true;
            Console.WriteLine("-- RslDictionary.EnsureConnected()");
            string certsServiceFile = Environment.GetEnvironmentVariable("certsServiceFile");

            var serviceIdentity = ServiceIdentity.ReadFromFile(certsServiceFile);

            _rslClient = new RSLClient(serviceIdentity, "KV", false);

            if (null != _rslClient)
            {
                _isConnected = true;
                Console.WriteLine("Connected()");
            }

            return _isConnected;
        }

        // Helper
        public static T GetValue<T>(String value)
        {
            return (T)Convert.ChangeType(value, typeof(T));
        }
    }
}
