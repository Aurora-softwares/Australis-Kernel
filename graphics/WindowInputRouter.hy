namespace Australis.Kernel.Graphics {
    public class WindowInputEvent {
        private int kind;
        private int owner;
        private int windowId;
        private int first;
        private int second;
        public WindowInputEvent(int inputKind, int inputOwner, int inputWindowId,
            int inputFirst, int inputSecond) {
            kind = inputKind; owner = inputOwner; windowId = inputWindowId;
            first = inputFirst; second = inputSecond;
        }
        // 1 pointer move, 2 button down, 3 button up, 4 key.
        public int Kind() { return kind; }
        public int Owner() { return owner; }
        public int WindowId() { return windowId; }
        public int First() { return first; }
        public int Second() { return second; }
    }

    // Window-manager input policy. A caller must bind Poll to an authenticated
    // process ID before exposing these events across a user/kernel boundary.
    public class WindowInputRouter {
        private WindowLayout layout;
        private WindowRenderer renderer;
        private WindowInputEvent[] events;
        private int count;
        private int dropped;
        private int capturedId;
        private int captureKind;
        private int startPointerX;
        private int startPointerY;
        private int startX;
        private int startY;
        private int startWidth;
        private int startHeight;
        private bool changed;
        public WindowInputRouter(WindowLayout inputLayout,
            WindowRenderer inputRenderer) {
            layout = inputLayout; renderer = inputRenderer;
            events = new WindowInputEvent[64]; count = 0; dropped = 0;
            capturedId = 0; captureKind = 0; changed = false;
        }
        public int Pending() { return count; }
        public int Dropped() { return dropped; }
        public bool Changed() { return changed; }
        public void ClearChanged() { changed = false; }
        private DesktopWindow Find(int id) {
            if (layout == null) { return null; }
            int i = 0;
            while (i < layout.Count()) {
                DesktopWindow window = layout.WindowAt(i);
                if (window.Id() == id) { return window; }
                i = i + 1;
            }
            return null;
        }
        private void Queue(int kind, DesktopWindow window, int first, int second) {
            if (window == null || !window.Visible()) { return; }
            if (count == events.Length) { dropped = dropped + 1; return; }
            events[count] = new WindowInputEvent(kind, window.Owner(),
                window.Id(), first, second);
            count = count + 1;
        }
        public WindowInputEvent Poll(int owner) {
            if (owner < 1) { return null; }
            int i = 0;
            while (i < count) {
                WindowInputEvent candidate = events[i];
                DesktopWindow window = Find(candidate.WindowId());
                if (window == null || window.Owner() != candidate.Owner() ||
                    !window.Visible()) {
                    int j = i;
                    while (j + 1 < count) { events[j] = events[j + 1]; j = j + 1; }
                    count = count - 1; events[count] = null;
                } else if (candidate.Owner() == owner) {
                    int j = i;
                    while (j + 1 < count) { events[j] = events[j + 1]; j = j + 1; }
                    count = count - 1; events[count] = null;
                    return candidate;
                } else { i = i + 1; }
            }
            return null;
        }
        public void DropOwner(int owner) {
            if (owner < 1) { return; }
            int i = 0;
            while (i < count) {
                if (events[i].Owner() == owner) {
                    int j = i;
                    while (j + 1 < count) { events[j] = events[j + 1]; j = j + 1; }
                    count = count - 1; events[count] = null;
                } else { i = i + 1; }
            }
            DesktopWindow captured = Find(capturedId);
            if (captured == null || captured.Owner() == owner) {
                capturedId = 0; captureKind = 0;
            }
        }
        private void DropWindow(int id) {
            int i = 0;
            while (i < count) {
                if (events[i].WindowId() == id) {
                    int j = i;
                    while (j + 1 < count) { events[j] = events[j + 1]; j = j + 1; }
                    count = count - 1; events[count] = null;
                } else { i = i + 1; }
            }
        }
        public void PointerMove(int x, int y) {
            if (layout == null || !layout.Ready()) { return; }
            if (renderer != null) { renderer.Hover(x, y); }
            DesktopWindow captured = Find(capturedId);
            if (captured == null || !captured.Visible()) {
                capturedId = 0; captureKind = 0;
            } else if (captureKind == 2) {
                if (layout.Move(captured.Owner(), capturedId,
                    startX + x - startPointerX, startY + y - startPointerY)) {
                    changed = true;
                }
            } else if (captureKind == 3) {
                if (layout.Resize(captured.Owner(), capturedId,
                    startWidth + x - startPointerX,
                    startHeight + y - startPointerY)) { changed = true; }
            } else if (captureKind == 1) {
                Queue(1, captured, x - captured.X(), y - captured.Y());
            }
            changed = true; // hover icons can change without moving a window.
        }
        public void PointerDown(int x, int y) {
            if (layout == null || !layout.Ready() || capturedId != 0) { return; }
            int resizeId = layout.ResizeHitTest(x, y);
            int id = layout.FocusAt(x, y);
            if (resizeId > 0) { id = resizeId; layout.Focus(id); }
            DesktopWindow window = Find(id);
            if (window == null) { return; }
            changed = true;
            int control = layout.ControlAt(x, y);
            if (control == 1) {
                DropWindow(id);
                if (renderer != null) { renderer.Remove(window.Owner(), id); }
                layout.Close(window.Owner(), id);
                return;
            }
            if (control == 2) {
                layout.Minimize(window.Owner(), id);
                return;
            }
            if (control == 3) {
                if (window.Maximized()) { layout.Unmaximize(window.Owner(), id); }
                else { layout.Maximize(window.Owner(), id); }
                return;
            }
            if (y < layout.BarHeight()) { return; }
            if (resizeId == id) {
                captureKind = 3;
            } else if (!window.Maximized() && y < window.Y() + 28) {
                captureKind = 2;
            } else {
                captureKind = 1;
                Queue(2, window, x - window.X(), y - window.Y());
            }
            capturedId = id;
            startPointerX = x; startPointerY = y;
            startX = window.X(); startY = window.Y();
            startWidth = window.Width(); startHeight = window.Height();
        }
        public void PointerUp(int x, int y) {
            DesktopWindow captured = Find(capturedId);
            if (captureKind == 1 && captured != null) {
                Queue(3, captured, x - captured.X(), y - captured.Y());
            }
            capturedId = 0; captureKind = 0;
        }
        public void Key(int code) {
            if (layout == null || !layout.Ready() || code < 0 || code > 65535) {
                return;
            }
            Queue(4, Find(layout.FocusedId()), code, 0);
        }
    }
}
