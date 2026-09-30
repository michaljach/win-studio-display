using System;
using System.Collections.Generic;
using System.Threading;

namespace StudioDisplayBrightness
{
    internal sealed class DisplayState
    {
        public readonly string Key;
        public readonly string Product;
        public readonly string Serial;
        public readonly int Percent; // -1 when the last read failed

        public DisplayState(string key, string product, string serial, int percent)
        {
            Key = key;
            Product = product;
            Serial = serial;
            Percent = percent;
        }
    }

    // Owns all HID I/O on one background thread, so enumeration and feature-report
    // round trips never block the UI. Brightness writes are coalesced per display:
    // while a slider is dragged only the newest value is sent.
    internal sealed class DisplayService : IDisposable
    {
        private sealed class Display
        {
            public string Key;
            public string Product;
            public string Serial;
            public List<string> Paths = new List<string>();
            public int Percent = -1;
        }

        private readonly object sync = new object();
        private readonly AutoResetEvent wake = new AutoResetEvent(false);
        private readonly Dictionary<string, int> pendingWrites = new Dictionary<string, int>();
        private readonly Thread thread;
        private List<Display> displays = new List<Display>();
        private bool rescanRequested;
        private bool refreshRequested;
        private volatile bool stopping;

        // Raised on the worker thread after a rescan (second argument true) or refresh.
        public event Action<DisplayState[], bool> Changed;

        public DisplayService()
        {
            thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Name = "Studio Display HID";
            thread.Start();
        }

        public void RequestRescan()
        {
            lock (sync)
            {
                rescanRequested = true;
            }

            wake.Set();
        }

        public void RequestRefresh()
        {
            lock (sync)
            {
                refreshRequested = true;
            }

            wake.Set();
        }

        public void SetBrightness(string key, int percent)
        {
            lock (sync)
            {
                pendingWrites[key] = Math.Max(0, Math.Min(100, percent));
            }

            wake.Set();
        }

        public void Dispose()
        {
            stopping = true;
            wake.Set();
            thread.Join(2000);
        }

        private void Run()
        {
            while (!stopping)
            {
                wake.WaitOne();
                while (!stopping)
                {
                    bool rescan;
                    bool refresh;
                    KeyValuePair<string, int>[] writes;
                    lock (sync)
                    {
                        rescan = rescanRequested;
                        refresh = refreshRequested;
                        rescanRequested = false;
                        refreshRequested = false;
                        writes = new KeyValuePair<string, int>[pendingWrites.Count];
                        ((ICollection<KeyValuePair<string, int>>)pendingWrites).CopyTo(writes, 0);
                        pendingWrites.Clear();
                    }

                    if (!rescan && !refresh && writes.Length == 0)
                    {
                        break;
                    }

                    // Writes first, so a read that follows reflects them.
                    foreach (var write in writes)
                    {
                        if (!Write(write.Key, write.Value))
                        {
                            rescan = true;
                        }
                    }

                    if (rescan)
                    {
                        Rescan();
                        Publish(true);
                    }
                    else if (refresh)
                    {
                        ReadAll();
                        Publish(false);
                    }
                }
            }
        }

        private bool Write(string key, int percent)
        {
            Display display = displays.Find(d => d.Key == key);
            if (display == null)
            {
                return true;
            }

            uint raw = StudioDisplayHid.ToRaw(percent);
            bool ok = true;
            foreach (string path in display.Paths)
            {
                try
                {
                    StudioDisplayHid.WriteRaw(path, raw);
                }
                catch (Exception ex)
                {
                    Log.Write("Write {0}% to {1} failed: {2}", percent, display.Key, ex.Message);
                    ok = false;
                }
            }

            if (ok)
            {
                display.Percent = percent;
            }

            return ok;
        }

        private void Rescan()
        {
            List<HidEndpoint> endpoints;
            try
            {
                endpoints = StudioDisplayHid.Enumerate();
            }
            catch (Exception ex)
            {
                Log.Write("Enumeration failed: {0}", ex.Message);
                endpoints = new List<HidEndpoint>();
            }

            // One Studio Display can expose more than one brightness endpoint; group by serial.
            var found = new List<Display>();
            foreach (HidEndpoint endpoint in endpoints)
            {
                string key = String.IsNullOrEmpty(endpoint.Serial) ? endpoint.Path.ToLowerInvariant() : endpoint.Serial;
                Display display = found.Find(d => d.Key == key);
                if (display == null)
                {
                    display = new Display();
                    display.Key = key;
                    display.Product = endpoint.Product;
                    display.Serial = endpoint.Serial;
                    found.Add(display);
                }

                display.Paths.Add(endpoint.Path);
            }

            displays = found;
            ReadAll();
            Log.Write("Found {0} display(s), {1} endpoint(s)", found.Count, endpoints.Count);
        }

        private void ReadAll()
        {
            foreach (Display display in displays)
            {
                display.Percent = -1;
                foreach (string path in display.Paths)
                {
                    uint raw;
                    if (StudioDisplayHid.TryReadRaw(path, out raw))
                    {
                        display.Percent = StudioDisplayHid.ToPercent(raw);
                        break;
                    }
                }
            }
        }

        private void Publish(bool rescanned)
        {
            var handler = Changed;
            if (handler == null)
            {
                return;
            }

            var states = new DisplayState[displays.Count];
            for (int i = 0; i < states.Length; i++)
            {
                Display d = displays[i];
                states[i] = new DisplayState(d.Key, d.Product, d.Serial, d.Percent);
            }

            handler(states, rescanned);
        }
    }
}
