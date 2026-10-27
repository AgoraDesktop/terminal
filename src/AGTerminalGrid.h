/*
 * AGTerminalGrid.h — the emulator: libtsm's state machine, and the grid it writes.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * THIS CLASS OWNS EVERYTHING ABOUT A TERMINAL THAT IS NOT PIXELS. Bytes off the pty go in with `-feed:length:`;
 * what must go back (escape-sequence replies, keys) comes out through `-terminalGrid:didWriteToPty:`; and the grid
 * itself is read through `-cellRows`, which is libtsm's own flat cell table — one `tsm_screen_cell` per cell, with
 * the colour already resolved to RGB and the selection already inversed.
 *
 * **WHY THE CELL TABLE RATHER THAN A CALLBACK.** libtsm offers both (`tsm_screen_draw`'s callback and
 * `tsm_screen_draw2`'s array). The array is what a renderer wants: it walks memory in cell order with no function
 * call per cell, and the row-major layout is the same order a raster paint wants. What the callback carries and the
 * array does not is a symbol's codepoint COUNT — a combining mark is one symbol of several codepoints — and this
 * revision of libtsm drops combining marks before they reach either door (see `libagora-tsm/README.md`), so nothing
 * is lost by taking the array. If that gap is ever fixed upstream, this is the door that has to change.
 *
 * **BORROWED, AND SAID SO.** `-cellRows` returns a pointer that belongs to the screen and is valid until the next
 * call. A renderer uses it inside one `-drawRect:` and lets it go.
 */
#ifndef AG_TERMINAL_GRID_H
#define AG_TERMINAL_GRID_H

#import <Foundation/Foundation.h>
#include <libtsm.h>

@class AGTerminalGrid;

@protocol AGTerminalGridDelegate <NSObject>

@optional
/* WHAT THE TERMINAL MUST SAY BACK TO THE PROGRAM: the replies to `DA1`/`DSR`, the bytes for a key, the wrapped
 * paste. libtsm hands them over as it produces them; a session writes them to the pty. */
- (void)terminalGrid:(AGTerminalGrid *)grid didWriteToPty:(NSData *)data;

/* The OSC 0/2 argument, with its own `0;`/`2;` prefix already removed. */
- (void)terminalGrid:(AGTerminalGrid *)grid didSetTitle:(NSString *)title;

- (void)terminalGridDidRingBell:(AGTerminalGrid *)grid;

@end

@interface AGTerminalGrid : NSObject
{
	struct tsm_screen *_screen;
	struct tsm_vte *_vte;
	id <AGTerminalGridDelegate> _delegate;	/* NOT RETAINED: the session owns the grid, not the other way round */
	BOOL _feeding;
}

- (id)initWithColumns:(NSUInteger)columns rows:(NSUInteger)rows;

/* ---- input ------------------------------------------------------------------------------------- */
- (void)feed:(const void *)bytes length:(NSUInteger)length;
- (void)feedData:(NSData *)data;

/* A KEYSTROKE, through libtsm's own handler — which is the whole escape-sequence table, honouring DECCKM, the keypad
 * mode, and the bracketed-paste and mouse modes. The four parameters are exactly what an `NSEvent` carries:
 * `keysym` is `-cg_keysym`, `ascii` the layout-independent ASCII keysym Control folds apply to, `modifiers` a
 * `TSM_*_MASK` combination, and `text` the character itself. */
- (void)keyWithKeysym:(unsigned int)keysym ascii:(unsigned int)ascii modifiers:(unsigned int)modifiers
		 text:(unsigned int)text;
- (void)paste:(NSString *)string;

/* ---- the grid ---------------------------------------------------------------------------------- */
- (void)resizeToColumns:(NSUInteger)columns rows:(NSUInteger)rows;
- (NSUInteger)columns;
- (NSUInteger)rows;

/* The flat cell table, row-major, `-columns` × `-rows`. BORROWED, and NULL if the screen refuses. */
- (const struct tsm_screen_cell *)cellRows;

/* Scrollback: the number of lines behind the view, and moving the view through them. */
- (NSUInteger)scrollbackLines;
- (void)scrollUp:(NSUInteger)lines;
- (void)scrollDown:(NSUInteger)lines;
- (BOOL)isScrolledBack;

- (unsigned int)cursorColumn;
- (unsigned int)cursorRow;
- (BOOL)isCursorVisible;

- (void)setDelegate:(id <AGTerminalGridDelegate>)delegate;
- (id <AGTerminalGridDelegate>)delegate;

@end

#endif /* AG_TERMINAL_GRID_H */
