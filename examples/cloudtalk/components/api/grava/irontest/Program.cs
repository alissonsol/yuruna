using System;
using System.Net;
using IronfleetIoFramework;
using IronRSLClient;
using KVMessages;

namespace irontest
{
    class Program
    {
        private static RSLClient _rslClient;
        private static bool _isConnected;

        static void Main(string[] args)
        {
            Console.WriteLine("Starting test!");

            if (null != args)
            {
                if (args.Length > 0)
                {
                    ContainsKey(args[0]);
                }
            }
        }

        private static bool EnsureConnected()        
        {
            if (_isConnected)
            {
                return true;
            }

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

        public static bool ContainsKey(string key)
        {
            Console.Write("-- RslDictionary.ContainsKey({0}): ", key.ToString());
            if (!EnsureConnected()) 
            {
                Console.WriteLine("False EnsureConnected()");
                return false;
            }

            string _key = key;
            bool isVerbose = true;
            Console.WriteLine("KVRequest request = new KVGetRequest(_key);");
            KVRequest request = new KVGetRequest(_key);
            Console.WriteLine("byte[] requestBytes = request.Encode();");
            byte[] requestBytes = request.Encode();
            Console.WriteLine("byte[] replyBytes = _rslClient.SubmitRequest(requestBytes, isVerbose);");
            byte[] replyBytes = _rslClient.SubmitRequest(requestBytes, isVerbose);
            Console.WriteLine("KVReply reply = KVReply.Decode(replyBytes, 0);");
            KVReply reply = KVReply.Decode(replyBytes, 0);
            if (reply is KVGetFoundReply grf)
            {
                Console.WriteLine("true --");
                return true;
            }

            Console.WriteLine("false --");
            return false;
        }

    }
}
