using System.Collections.Generic;

namespace RSL
{
    /// <summary>
    /// Replicated State Library Dictionary
    /// </summary>
    public class RslDictionary<TKey, TValue> : Dictionary<TKey, TValue>
    {
        public RslDictionary() : base() { }
        public RslDictionary(int capacity) : base(capacity) { }

        public TValue Set(TKey key, TValue value)
        {
            System.Console.WriteLine(string.Format("RslDictionary.Set[{0}] = {1}", key, value));            
            if (ContainsKey(key))
            {
                this[key] = value;
            }
            else
            {
                Add(key, value);
            }

            return value;
        }

        public TValue Get(TKey key)
        {
            System.Console.WriteLine(string.Format("RslDictionary.Get[{0}]", key));            
            if (ContainsKey(key))
            {
                return this[key];
            }

            return default;
        }

        public TValue Delete(TKey key)
        {
            System.Console.WriteLine(string.Format("RslDictionary.Delete[{0}]", key));            
            TValue value = default;

            if (ContainsKey(key))
            {
                value = this[key];
            }

            Remove(key);

            return value;
        }
    }
}
