
# Dockerfile fragment appended by litterbox-assemble (`append = claude.extra.Dockerfile` in claude.litterbox).
# It is copied as-is and runs as root during `litterbox build`, so read it. The author's original also replaced
# /usr/bin/bwrap (to let glycin run unsandboxed) and pre-approved WebUSB devices in Chromium; both weaken the
# sandbox and are left out of this example on purpose.

# xdg-open inside the box: hand URLs to a FIFO the host reads (~/.host-open), or put them on the clipboard.
# Only useful if you run a host-side reader for that FIFO; without it URLs just go to the clipboard.
RUN <<'EOF2'
cat > /usr/local/bin/xdg-open <<'EOS'
#!/bin/sh
url="$1"
fifo="$HOME/.host-open"
if [ -p "$fifo" ] && timeout 2 sh -c 'printf "%s\n" "$1" > "$2"' sh "$url" "$fifo"; then
  exit 0
fi
printf '%s' "$url" | wl-copy
echo "litterbox: copied to clipboard: $url" >&2
EOS
chmod +x /usr/local/bin/xdg-open
EOF2

# GTK dark defaults (the GTK packages come from the manifest)
RUN mkdir -p /etc/gtk-3.0 && \
    printf '%s\n' \
      '[Settings]' \
      'gtk-theme-name=Adwaita-dark' \
      'gtk-application-prefer-dark-theme=1' \
      'gtk-icon-theme-name=Adwaita' \
      > /etc/gtk-3.0/settings.ini && \
    glib-compile-schemas /usr/share/glib-2.0/schemas && \
    gdk-pixbuf-query-loaders --update-cache && \
    update-mime-database /usr/share/mime

# Generate the locale LANG points at (the template already sets LANG=en_US.UTF-8)
RUN sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen

# Runs once, on first start, to set up the mounted home directory (replaces the template's stub).
RUN <<'EOF2'
cat <<'EOT' > /prep-home.sh
#!/usr/bin/env sh
mkdir -p ~/.claude ~/.local/bin

# ~/.claude-shared is a read-only mount of a folder on the host (see the volume line in the manifest)
for d in skills agents commands; do
  ln -sfn ~/.claude-shared/$d ~/.claude/$d
done

[ -f ~/.claude/CLAUDE.md ] || cat > ~/.claude/CLAUDE.md <<'MD'
@~/.claude-shared/CLAUDE.md

## Environment (claude litterbox)
- Claude runs inside a Litterbox (rootless podman). Only this home directory, ~/Projects and ~/.claude-shared are shared with the host.
- ~/Projects is the host's project folder (read-write). ~/.claude-shared is read-only; do not try to edit it.
- There is no sudo. System packages come from the Dockerfile; if something is missing, tell the user the package name instead of trying to install it.
- User-level installs into $HOME (pipx, npm with a home prefix, cargo) are fine.
- Files in ~/Projects can be run by the host. Do not add or change git hooks, .vscode tasks, or hooks in a project's .claude/settings.json without asking.
MD
EOT
chmod +x /prep-home.sh
chown $USER /prep-home.sh
EOF2

# Set your own timezone
RUN ln -sf /usr/share/zoneinfo/UTC /etc/localtime
