namespace Toastrack {
    /* Notifications in the order they're listed, in sections by local day */
    public class NotificationList : Object, ListModel, Gtk.SectionModel {
        private GenericArray<Notification> items = new GenericArray<Notification> ();

        public bool newest_first { get; set; default = true; }

        public Type get_item_type () {
            return typeof (Notification);
        }

        public uint get_n_items () {
            return items.length;
        }

        public Object? get_item (uint position) {
            return position < items.length ? items[position] : null;
        }

        public Notification? last () {
            return items.length > 0 ? items[items.length - 1] : null;
        }

        public void get_section (uint position, out uint start, out uint end) {
            if (position >= items.length) {
                start = items.length;
                end = uint.MAX;
                return;
            }
            var day = Utils.day_key (items[position].received);
            start = position;
            while (start > 0 && Utils.day_key (items[start - 1].received) == day) {
                start--;
            }
            end = position + 1;
            while (end < items.length && Utils.day_key (items[end].received) == day) {
                end++;
            }
        }

        public void replace_all (GenericArray<Notification> new_items) {
            var removed = items.length;
            items = new_items;
            items_changed (0, removed, items.length);
        }

        public void append_all (GenericArray<Notification> more) {
            var position = items.length;
            foreach (var n in more) {
                items.add (n);
            }
            items_changed (position, 0, more.length);
        }

        public int find (int64 id) {
            for (var i = 0; i < items.length; i++) {
                if (items[i].id == id) {
                    return i;
                }
            }
            return -1;
        }

        public void remove (uint position) {
            items.remove_index (position);
            items_changed (position, 1, 0);
        }

        /* Where @n goes in the order */
        public uint position_for (Notification n) {
            uint low = 0, high = items.length;
            while (low < high) {
                var mid = (low + high) / 2;
                if (comes_before (items[mid], n)) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }
            return low;
        }

        public void insert (uint position, Notification n) {
            items.insert ((int) position, n);
            items_changed (position, 0, 1);
        }

        private bool comes_before (Notification a, Notification b) {
            var cmp = a.received_at != b.received_at ? (a.received_at < b.received_at ? -1 : 1)
                                                     : (a.id < b.id ? -1 : (a.id > b.id ? 1 : 0));
            return newest_first ? cmp > 0 : cmp < 0;
        }
    }
}
