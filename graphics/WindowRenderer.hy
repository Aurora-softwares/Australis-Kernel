namespace Australis.Kernel.Graphics {
    public class WindowPaint {
        private int id;
        private int owner;
        private PixelSurface pixels;
        public WindowPaint(int inputId, int inputOwner, PixelSurface inputPixels) {
            id = inputId; owner = inputOwner; pixels = inputPixels;
        }
        public int Id() { return id; }
        public int Owner() { return owner; }
        public PixelSurface Pixels() { return pixels; }
    }


	public class RetainedWindowCache {
		private int id;
		private PixelSurface pixels;
		private bool valid;
		private bool focused;
		private bool maximized;
		private int hoveredControl;

		public RetainedWindowCache(int inputId, int width, int height) {
			id = inputId;
			pixels = new PixelSurface(width, height);
			valid = false;
			focused = false;
			maximized = false;
			hoveredControl = 0;
		}

		public int Id() { return id; }
		public PixelSurface Pixels() { return pixels; }

		public bool Matches(bool nextFocused,
			bool nextMaximized, int nextHovered) {
			return valid &&
				focused == nextFocused &&
				maximized == nextMaximized &&
				hoveredControl == nextHovered;
		}

		public void Invalidate() {
			valid = false;
		}

		public void Updated(bool nextFocused,
			bool nextMaximized, int nextHovered) {
			focused = nextFocused;
			maximized = nextMaximized;
			hoveredControl = nextHovered;
			valid = true;
		}
	}

    // Software compositor prototype. Its input is copied into service-owned
    // surfaces; no client sees the display's physical framebuffer address.
    public class WindowRenderer {
        private PixelSurface frame;
        private PixelSurface wallpaper;
        private PixelSurface normalBar;
		private RetainedWindowCache[] windowCaches;
        private WindowLayout layout;
        private WindowPaint[] paints;
        private int clipLeft;
        private int clipTop;
        private int clipRight;
        private int clipBottom;
        private int hoverX;
        private int hoverY;
		private int windowCacheBuilds;

		public WindowRenderer(WindowLayout inputLayout) {
			frame = null;
			wallpaper = null;
            normalBar = null;
            layout = inputLayout;
            paints = new WindowPaint[8];
			windowCaches = new RetainedWindowCache[8];
			hoverX = -1;
			hoverY = -1;
			windowCacheBuilds = 0;
            if (layout != null && layout.Ready()) {
                frame = new PixelSurface(layout.DisplayWidth(), layout.DisplayHeight());
                wallpaper = new PixelSurface(layout.DisplayWidth(),
                    layout.DisplayHeight());
                normalBar = new PixelSurface(layout.DisplayWidth(),
                    layout.BarHeight());
                int y = 0;
                while (y < layout.DisplayHeight()) {
                    int x = 0;
                    while (x < layout.DisplayWidth()) {
                        wallpaper.SetPixel(x, y, WallpaperColor(x, y));
                        x = x + 1;
                    }
                    y = y + 1;
                }
                y = 0;
                while (y < layout.BarHeight()) {
                    int x = 0;
                    while (x < layout.DisplayWidth()) {
                        normalBar.SetPixel(x, y, BlurredBarColor(x, y));
                        x = x + 1;
                    }
                    y = y + 1;
                }
            }
        }

        public bool Ready() {
            return frame != null && frame.Ready() &&
                wallpaper != null && wallpaper.Ready() &&
                normalBar != null && normalBar.Ready();
        }

        public void Hover(int x, int y) {
			hoverX = x;
			hoverY = y;
		}

		private DesktopWindow FindWindow(int id) {
            int i = 0;
            while (i < layout.Count()) {
                DesktopWindow window = layout.WindowAt(i);
                if (window.Id() == id) { return window; }
                i = i + 1;
            }
            return null;
        }

		private WindowPaint FindPaint(int id) {
            int i = 0;
            while (i < paints.Length) {
                if (paints[i] != null && paints[i].Id() == id) { return paints[i]; }
                i = i + 1;
            }
            return null;
        }

		public bool Submit(int owner, int id, PixelSurface source) {
            if (!Ready() || source == null || !source.Ready()) { return false; }
            DesktopWindow window = FindWindow(id);
            if (window == null || window.Owner() != owner ||
                source.Width() > window.Width() ||
                source.Height() > window.Height()) { return false; }
            WindowPaint old = FindPaint(id);
            if (old != null) {
                if (old.Owner() != owner || old.Pixels().Width() != source.Width() || old.Pixels().Height() != source.Height()) {
					return false;
				}
				bool updated = old.Pixels().Blit(source, 0, 0, 255);
				if (updated) {
					InvalidateCache(id);
				}
				return updated;
            }
            int slot = 0;
            while (slot < paints.Length && paints[slot] != null) { slot = slot + 1; }
            if (slot == paints.Length) { return false; }
            PixelSurface copy = new PixelSurface(source.Width(), source.Height());
            if (!copy.Ready() || !copy.Blit(source, 0, 0, 255)) { return false; }
            paints[slot] = new WindowPaint(id, owner, copy);
            return true;
        }

		public bool Remove(int owner, int id) {
            int i = 0;
            while (i < paints.Length) {
                if (paints[i] != null && paints[i].Id() == id && paints[i].Owner() == owner) {
					paints[i] = null;
					InvalidateCache(id);
					return true;
				}
                i = i + 1;
            }
            return false;
        }

		private int WallpaperColor(int x, int y) {
            int width = layout.DisplayWidth();
            int height = layout.DisplayHeight();
            int red = 27 + y * 24 / height;
            int green = 38 + x * 30 / width;
            int blue = 56 + (x + y) * 28 / (width + height);
            return red * 65536 + green * 256 + blue;
        }

		private void Put(int x, int y, int color) {
            if (x >= clipLeft && x < clipRight &&
                y >= clipTop && y < clipBottom) {
                frame.SetPixel(x, y, color);
            }
        }

        private void Wallpaper() {
            frame.CopyRegion(wallpaper, clipLeft, clipTop,
                clipLeft, clipTop, clipRight - clipLeft,
                clipBottom - clipTop);
        }

		private int BlurredBarColor(int x, int y) {
            int red = 0; int green = 0; int blue = 0; int samples = 0;
            int dy = -2;
            while (dy <= 2) {
                int sampleY = y + dy;
                if (sampleY >= 0 && sampleY < layout.BarHeight()) {
                    int dx = -2;
                    while (dx <= 2) {
                        int sampleX = x + dx;
                        if (sampleX >= 0 && sampleX < layout.DisplayWidth()) {
                            int color = wallpaper.Pixel(sampleX, sampleY);
                            red = red + color / 65536;
                            green = green + color / 256 % 256;
                            blue = blue + color % 256;
                            samples = samples + 1;
                        }
                        dx = dx + 1;
                    }
                }
                dy = dy + 1;
            }
            int blurred = (red / samples) * 65536 +
                (green / samples) * 256 + blue / samples;
            return PixelSurface.BlendColor(0xDDE7EE, blurred, 160);
        }

		private bool PaintWindow(DesktopWindow window) {
			if (!window.Visible()) {
				return true;
			}

			PixelSurface cached = CachedWindow(window);

			if (cached == null) {
				return false;
			}

			int row = clipTop - window.Y();
			if (row < 0) {
				row = 0;
			}

			int lastRow = clipBottom - window.Y();
			if (lastRow > window.Height()) {
				lastRow = window.Height();
			}

			while (row < lastRow) {
				int screenY = window.Y() + row;
				int first = 0;
				int last = window.Width();

				// Preserve the existing rounded window corners.
				if (!window.Maximized() &&
					(row < 10 || row >= window.Height() - 10)) {

					while (first < last &&
						!PixelSurface.RoundedContains(
							first, row,
							window.Width(), window.Height(), 10)) {
						first = first + 1;
					}

					while (last > first &&
						!PixelSurface.RoundedContains(
							last - 1, row,
							window.Width(), window.Height(), 10)) {
						last = last - 1;
					}
				}

				int clipFirst = clipLeft - window.X();
				int clipLast = clipRight - window.X();

				if (clipFirst > first) {
					first = clipFirst;
				}
				if (clipLast < last) {
					last = clipLast;
				}

				if (first < last &&
					screenY >= 0 &&
					screenY < layout.DisplayHeight()) {

					if (!frame.CopyRegion(
						cached,
						first, row,
						window.X() + first, screenY,
						last - first, 1)) {
						return false;
					}
				}

				row = row + 1;
			}

			return true;
		}

		private void DrawIcon(int kind, int centerX, int centerY) {
            int offset = -2;
            while (offset <= 2) {
                if (kind == 1) {
                    Put(centerX + offset, centerY + offset, 0x383838);
                    Put(centerX + offset, centerY - offset, 0x383838);
                } else if (kind == 2) {
                    Put(centerX + offset, centerY + 2, 0x383838);
                } else {
                    Put(centerX + offset, centerY, 0x383838);
                    Put(centerX, centerY + offset, 0x383838);
                }
                offset = offset + 1;
            }
        }

		private void DrawCircle(int centerX, int centerY, int radius,
            int color) {
            int y = centerY - radius;
            if (y < clipTop) { y = clipTop; }
            int bottom = centerY + radius + 1;
            if (bottom > clipBottom) { bottom = clipBottom; }
            while (y < bottom) {
                int x = centerX - radius;
                if (x < clipLeft) { x = clipLeft; }
                int right = centerX + radius + 1;
                if (right > clipRight) { right = clipRight; }
                while (x < right) {
                    int dx = x - centerX; int dy = y - centerY;
                    if (dx * dx + dy * dy <= radius * radius) {
                        frame.SetPixel(x, y, color);
                    }
                    x = x + 1;
                }
                y = y + 1;
            }
        }

		private void DrawControls(int id, int left, int top) {
            int hoverId = layout.HitTest(hoverX, hoverY);
            int hoveredControl = layout.ControlAt(hoverX, hoverY);
            int kind = 1;
            while (kind <= 3) {
                int centerX = left + 18 + (kind - 1) * 22;
                int centerY = top + 16;
                int color = 0xFF5F57;
                if (kind == 2) { color = 0xFEBC2E; }
                if (kind == 3) { color = 0x28C840; }
                DrawCircle(centerX, centerY, 7, color);
                if (hoverId == id && hoveredControl == kind) {
                    DrawIcon(kind, centerX, centerY);
                }
                kind = kind + 1;
            }
        }

		private void TopBar() {
            int bar = layout.BarHeight();
            if (clipTop >= bar) { return; }
            if (layout.TopBarMode() == 2) {
                int y = clipTop;
                while (y < clipBottom && y < bar) {
                    int x = clipLeft;
                    while (x < clipRight) {
                        frame.SetPixel(x, y, 0); x = x + 1;
                    }
                    y = y + 1;
                }
                int i = layout.Count() - 1;
                while (i >= 0) {
                    DesktopWindow window = layout.WindowAt(i);
                    if (window.Visible() && window.Maximized()) {
                        DrawControls(window.Id(), 0, 0);
                        return;
                    }
                    i = i - 1;
                }
                return;
            }
            int bottom = clipBottom;
            if (bottom > bar) { bottom = bar; }
            frame.CopyRegion(normalBar, clipLeft, clipTop,
                clipLeft, clipTop, clipRight - clipLeft,
                bottom - clipTop);
        }

		public PixelSurface Compose() {
            if (!Ready()) { return null; }
            return ComposeRegion(0, 0, layout.DisplayWidth(),
                layout.DisplayHeight());
        }

		public PixelSurface ComposeRegion(int x, int y, int width,
            int height) {
            if (!Ready() || x < 0 || y < 0 || width < 1 || height < 1 ||
                (long)x + width > layout.DisplayWidth() ||
                (long)y + height > layout.DisplayHeight()) { return null; }
            clipLeft = x; clipTop = y;
            clipRight = x + width; clipBottom = y + height;
            Wallpaper();
            int i = 0;
            while (i < layout.Count()) {
                if (!PaintWindow(layout.WindowAt(i))) {
					return null;
				}
                i = i + 1;
            }
            TopBar();
            return frame;
        }

		public PixelSurface ComposeDamage(DamageTracker damage) {
            if (!Ready() || damage == null ||
                damage.Width() != layout.DisplayWidth() ||
                damage.Height() != layout.DisplayHeight()) { return null; }
            int i = 0;
            while (i < damage.Count()) {
                DamageRect rect = damage.At(i);
                if (rect == null || ComposeRegion(rect.X(), rect.Y(),
                    rect.Width(), rect.Height()) == null) { return null; }
                i = i + 1;
            }
            return frame;
        }

		public int WindowCacheBuilds() {
			return windowCacheBuilds;
		}

		private RetainedWindowCache FindCache(int id) {
			int i = 0;
			while (i < windowCaches.Length) {
				if (windowCaches[i] != null &&
					windowCaches[i].Id() == id) {
					return windowCaches[i];
				}
				i = i + 1;
			}
			return null;
		}

		private void InvalidateCache(int id) {
			RetainedWindowCache cache = FindCache(id);
			if (cache != null) {
				cache.Invalidate();
			}
		}

		private void CleanupCaches() {
			int i = 0;
			while (i < windowCaches.Length) {
				if (windowCaches[i] != null &&
					FindWindow(windowCaches[i].Id()) == null) {
					windowCaches[i] = null;
				}
				i = i + 1;
			}
		}

		private PixelSurface CachedWindow(DesktopWindow window) {
			int id = window.Id();
			int width = window.Width();
			int height = window.Height();

			bool focused = layout.FocusedId() == id;
			bool maximized = window.Maximized();

			int hovered = 0;
			if (layout.HitTest(hoverX, hoverY) == id) {
				hovered = layout.ControlAt(hoverX, hoverY);
			}

			RetainedWindowCache cache = FindCache(id);

			if (cache == null ||
				cache.Pixels().Width() != width ||
				cache.Pixels().Height() != height) {

				int slot = 0;
				while (slot < windowCaches.Length &&
					windowCaches[slot] != null &&
					windowCaches[slot].Id() != id) {
					slot = slot + 1;
				}

				if (slot == windowCaches.Length) {
					return null;
				}

				cache = new RetainedWindowCache(id, width, height);
				if (!cache.Pixels().Ready()) {
					return null;
				}

				windowCaches[slot] = cache;
			}

			if (cache.Matches(focused, maximized, hovered)) {
				return cache.Pixels();
			}

			PixelSurface surface = cache.Pixels();

			// Build the complete window background.
			if (!surface.Fill(0xE8EDF2)) {
				return null;
			}

			int titleHeight = 28;
			if (maximized) {
				titleHeight = 0;
			}

			if (titleHeight > 0) {
				int header = 0xC5CCD5;
				if (focused) {
					header = 0xE1E6EC;
				}

				if (!surface.FillRect(
					0, 0, width, titleHeight, header)) {
					return null;
				}
			}

			// Copy already-submitted application content.
			WindowPaint paint = FindPaint(id);

			if (paint != null) {
				PixelSurface content = paint.Pixels();

				int copyWidth = content.Width();
				int copyHeight = content.Height();

				if (copyWidth > width) {
					copyWidth = width;
				}

				if (copyHeight > height - titleHeight) {
					copyHeight = height - titleHeight;
				}

				if (copyWidth > 0 && copyHeight > 0) {
					if (!surface.CopyRegion(
						content, 0, 0,
						0, titleHeight,
						copyWidth, copyHeight)) {
						return null;
					}
				}
			}

			// Cache window controls and hover symbols.
			if (!maximized) {
				int kind = 1;

				while (kind <= 3) {
					int cx = 18 + (kind - 1) * 22;
					int cy = 16;

					int color = 0xFF5F57;
					if (kind == 2) { color = 0xFEBC2E; }
					if (kind == 3) { color = 0x28C840; }

					if (!surface.FillCircle(cx, cy, 7, color)) {
						return null;
					}

					if (hovered == kind) {
						int offset = -2;

						while (offset <= 2) {
							if (kind == 1) {
								surface.SetPixel(
									cx + offset, cy + offset, 0x383838);
								surface.SetPixel(
									cx + offset, cy - offset, 0x383838);
							} else if (kind == 2) {
								surface.SetPixel(
									cx + offset, cy + 2, 0x383838);
							} else {
								surface.SetPixel(
									cx + offset, cy, 0x383838);
								surface.SetPixel(
									cx, cy + offset, 0x383838);
							}
							offset = offset + 1;
						}
					}

					kind = kind + 1;
				}
			}

			cache.Updated(focused, maximized, hovered);
			windowCacheBuilds = windowCacheBuilds + 1;

			return surface;
		}

    }
}
