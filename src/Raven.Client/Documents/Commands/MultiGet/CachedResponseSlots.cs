using System;
using System.Buffers;
using Raven.Client.Http;
using Sparrow.Json;

namespace Raven.Client.Documents.Commands.MultiGet
{
    /// <summary>
    /// Keeps the local copies that a single multi_get execution may answer from, one slot per
    /// request in the batch. The backing array is borrowed for the duration of the execution and
    /// handed back once the responses were produced.
    /// </summary>
    internal sealed class CachedResponseSlots : IDisposable
    {
        internal struct Slot
        {
            public HttpCache.ReleaseCacheItem Lease;

            public BlittableJsonReaderObject Body;
        }

        private readonly int _span;

        private Slot[] _slots;

        public CachedResponseSlots(int span)
        {
            _span = span;
            _slots = ArrayPool<Slot>.Shared.Rent(span);
        }

        public void Attach(int index, HttpCache.ReleaseCacheItem lease, BlittableJsonReaderObject body)
        {
            _slots[index].Lease = lease;
            _slots[index].Body = body;
        }

        public BlittableJsonReaderObject Peek(int index)
        {
            return _slots[index].Body;
        }

        public void Renew(int index)
        {
            _slots[index].Lease.NotModified();
        }

        public void Dispose()
        {
            var slots = _slots;
            if (slots == null)
                return;

            _slots = null;

            for (int i = 0; i < _span; i++)
                slots[i].Lease.Dispose();

            ArrayPool<Slot>.Shared.Return(slots);
        }
    }
}
