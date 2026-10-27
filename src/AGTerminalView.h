/*
 * AGTerminalView.h — the glass: the grid painted, and the keys split by what they mean.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * THE SPLIT IS APPLE'S OWN, and it is the design this whole stack was pointed at:
 *
 *   - A key that COMMANDS — an arrow, Home, an F key, Escape, Tab, a Control combination — is turned into an escape
 *     sequence by the emulator (`AGTerminalGrid -keyWithKeysym:…`), from the keysym, the ASCII keysym, the modifiers
 *     and the character. libtsm owns that table, including DECCKM and the keypad mode.
 *   - A key that TYPES goes through `-interpretKeyEvents:`, so the input context composes it: a dead key becomes one
 *     composed character (the AppKit's `AGInputMethod`), and an input method can slot in without this view changing.
 *     What comes back is `-insertText:`, which is bytes on the pty.
 *
 * Command-modified keys never reach either half: `NSApplication` offers them to the main menu first, and a terminal's
 * copy and paste are menu items (`-copy:` / `-paste:`), which is also why `Ctrl+Shift+C` can be one — the event
 * carries the key's own name now, so a key equivalent can match it.
 */
#ifndef AG_TERMINAL_VIEW_H
#define AG_TERMINAL_VIEW_H

#import <AppKit/NSView.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSTextInput.h>

#import "AGTerminalSession.h"

@class AGTerminalRenderer;

/* **`NSTextInput` IS NOT DECORATION — IT IS WHAT MAKES TYPING WORK.** `NSView -inputContext` answers a context ONLY for
 * a view that conforms to this protocol (`NSView.m` says so in as many words), and `-interpretKeyEvents:` hands each
 * event to that context. A terminal that did not conform was a terminal whose `-interpretKeyEvents:` was a no-op: the
 * first live run accepted Enter (which takes the `-doCommandBySelector:` path, and that is plain `NSResponder`) and
 * silently dropped every printable character. So the view is a text input client, and the four doors a terminal can
 * actually answer are answered below; the rest say why not rather than pretending. */
@interface AGTerminalView : NSView <AGTerminalSessionDelegate, NSTextInput>
{
	AGTerminalSession *_session;	/* RETAINED: the view is the session's owner in this slice */
	AGTerminalRenderer *_renderer;	/* RETAINED */
	NSEvent *_keyEvent;		/* the event being interpreted, so a command can read its modifiers */
	NSString *_markedString;	/* RETAINED: a composition in flight, which a terminal shows by composing */
	NSUInteger _columns;
	NSUInteger _rows;
}

- (id)initWithFrame:(NSRect)frame session:(AGTerminalSession *)session renderer:(AGTerminalRenderer *)renderer;

- (AGTerminalSession *)session;
- (AGTerminalRenderer *)renderer;

/* The size in cells the view's bounds currently afford, and the same call applied to the session (grid + pty). */
- (void)applySizeToSession;

@end

#endif /* AG_TERMINAL_VIEW_H */
