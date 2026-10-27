/*
 * AGTerminalGrid.m — libtsm's doors, and the ownership around them.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "AGTerminalGrid.h"

/* libtsm's callbacks are C functions with a `void *data`, and this tree is MRC, so the bridge is a plain cast: the
 * grid passes itself, and the grid outlives the vte because it owns it. */
static void fn_write(struct tsm_vte *vte, const char *u8, size_t len, void *data)
{
	AGTerminalGrid *grid = (AGTerminalGrid *)data;
	id <AGTerminalGridDelegate> delegate;

	(void)vte;
	if (grid == nil || len == 0) {
		return;
	}
	delegate = [grid delegate];
	if (delegate != nil && [delegate respondsToSelector:@selector(terminalGrid:didWriteToPty:)]) {
		[delegate terminalGrid:grid didWriteToPty:[NSData dataWithBytes:u8 length:len]];
	}
}

/* **THE OSC ARGUMENT ARRIVES RAW, `0;` INCLUDED** — libtsm hands over what the program sent, not a parsed title, so
 * the title is the part after the first semicolon and only for the two commands that set one (`0` window, `2` window
 * name). Anything else is left to a later slice rather than guessed at. */
static void fn_osc(struct tsm_vte *vte, const char *title, size_t len, void *data)
{
	AGTerminalGrid *grid = (AGTerminalGrid *)data;
	id <AGTerminalGridDelegate> delegate;
	NSString *string;
	NSRange semicolon;

	(void)vte;
	if (grid == nil || title == NULL) {
		return;
	}
	delegate = [grid delegate];
	if (delegate == nil || ![delegate respondsToSelector:@selector(terminalGrid:didSetTitle:)]) {
		return;
	}
	string = [[NSString alloc] initWithBytes:title length:len encoding:NSUTF8StringEncoding];
	if (string == nil) {
		/* A title that is not UTF-8 is not a title this application can show; the raw bytes are dropped rather than
		 * mangled into the window's name. */
		return;
	}
	semicolon = [string rangeOfString:@";"];
	if (semicolon.location == NSNotFound ||
	    !([[string substringToIndex:semicolon.location] isEqualToString:@"0"] ||
	      [[string substringToIndex:semicolon.location] isEqualToString:@"2"])) {
		[string release];
		return;
	}
	[delegate terminalGrid:grid didSetTitle:[string substringFromIndex:semicolon.location + 1]];
	[string release];
}

static void fn_bell(struct tsm_vte *vte, void *data)
{
	AGTerminalGrid *grid = (AGTerminalGrid *)data;
	id <AGTerminalGridDelegate> delegate;

	(void)vte;
	if (grid == nil) {
		return;
	}
	delegate = [grid delegate];
	if (delegate != nil && [delegate respondsToSelector:@selector(terminalGridDidRingBell:)]) {
		[delegate terminalGridDidRingBell:grid];
	}
}

@implementation AGTerminalGrid

- (id)initWithColumns:(NSUInteger)columns rows:(NSUInteger)rows
{
	self = [super init];
	if (self == nil) {
		return nil;
	}
	if (columns == 0 || rows == 0) {
		columns = 80;
		rows = 24;
	}
	if (tsm_screen_new(&_screen, NULL, NULL) != 0 || _screen == NULL) {
		[self release];
		return nil;
	}
	tsm_screen_resize(_screen, (unsigned int)columns, (unsigned int)rows);
	/* **A SCROLLBACK BECAUSE A TERMINAL WITHOUT ONE IS A PAGER.** libtsm keeps the lines in the screen and moves the
	 * view through them (`-scrollUp:`/`-scrollDown:`), so what a view draws at an offset is already the right lines. */
	tsm_screen_set_max_sb(_screen, 10000);
	if (tsm_vte_new(&_vte, _screen, fn_write, self, NULL, NULL) != 0 || _vte == NULL) {
		tsm_screen_unref(_screen);
		_screen = NULL;
		[self release];
		return nil;
	}
	/* THE CALLBACKS THAT ARE NOT THE WRITE ONE, set after the object exists: OSC (a title), the bell, and
	 * nothing for the log — a log callback is upstream's debugging channel and this application has its own. */
	tsm_vte_set_osc_cb(_vte, fn_osc, self);
	tsm_vte_set_bell_cb(_vte, fn_bell, self);
	return self;
}

- (void)dealloc
{
	if (_vte != NULL) {
		tsm_vte_unref(_vte);
		_vte = NULL;
	}
	if (_screen != NULL) {
		tsm_screen_unref(_screen);
		_screen = NULL;
	}
	[super dealloc];
}

/* ---- input ------------------------------------------------------------------------------------- */

- (void)feed:(const void *)bytes length:(NSUInteger)length
{
	if (_vte == NULL || bytes == NULL || length == 0) {
		return;
	}
	/* A NESTED FEED IS NOT POSSIBLE: a write callback that feeds the grid again would be a parser inside a parser.
	 * Refusing it is cheaper than the crash it would otherwise become, and nothing in this application does it. */
	if (_feeding) {
		return;
	}
	_feeding = YES;
	tsm_vte_input(_vte, (const char *)bytes, (size_t)length);
	_feeding = NO;
}

- (void)feedData:(NSData *)data
{
	[self feed:[data bytes] length:[data length]];
}

- (void)keyWithKeysym:(unsigned int)keysym ascii:(unsigned int)ascii modifiers:(unsigned int)modifiers
		 text:(unsigned int)text
{
	if (_vte == NULL) {
		return;
	}
	tsm_vte_handle_keyboard(_vte, keysym, ascii, modifiers, text);
}

- (void)paste:(NSString *)string
{
	if (_vte == NULL || string == nil) {
		return;
	}
	tsm_vte_paste(_vte, [string UTF8String]);
}

/* ---- the grid ---------------------------------------------------------------------------------- */

- (void)resizeToColumns:(NSUInteger)columns rows:(NSUInteger)rows
{
	if (_screen == NULL || columns == 0 || rows == 0) {
		return;
	}
	tsm_screen_resize(_screen, (unsigned int)columns, (unsigned int)rows);
}

- (NSUInteger)columns
{
	return _screen != NULL ? tsm_screen_get_width(_screen) : 0;
}

- (NSUInteger)rows
{
	return _screen != NULL ? tsm_screen_get_height(_screen) : 0;
}

- (const struct tsm_screen_cell *)cellRows
{
	if (_screen == NULL) {
		return NULL;
	}
	return tsm_screen_draw2(_screen);
}

- (NSUInteger)scrollbackLines
{
	return _screen != NULL ? tsm_screen_sb_get_line_count(_screen) : 0;
}

- (void)scrollUp:(NSUInteger)lines
{
	if (_screen != NULL && lines > 0) {
		tsm_screen_sb_up(_screen, (unsigned int)lines);
	}
}

- (void)scrollDown:(NSUInteger)lines
{
	if (_screen != NULL && lines > 0) {
		tsm_screen_sb_down(_screen, (unsigned int)lines);
	}
}

/* **"SCROLLED BACK" IS A POSITION, NOT A MODE — AND libtsm COUNTS IT FROM THE TOP.** `tsm_screen_sb_get_line_pos`
 * answers `sb.pos_num`, which is the number of the line the view starts at counted DOWN from the oldest kept line;
 * the live screen is `sb.pos == NULL` and reports the line COUNT, because there is nothing above it. So "scrolled
 * back" is exactly "the position is less than the number of lines", and the tempting `> 0` is its mirror image —
 * MEASURED, and it made this probe assert the opposite of the truth on a screen nobody had scrolled. */
- (BOOL)isScrolledBack
{
	if (_screen == NULL) {
		return NO;
	}
	return tsm_screen_sb_get_line_pos(_screen) < tsm_screen_sb_get_line_count(_screen);
}

- (unsigned int)cursorColumn
{
	return _screen != NULL ? tsm_screen_get_cursor_x(_screen) : 0;
}

- (unsigned int)cursorRow
{
	return _screen != NULL ? tsm_screen_get_cursor_y(_screen) : 0;
}

- (BOOL)isCursorVisible
{
	if (_screen == NULL) {
		return NO;
	}
	return (tsm_screen_get_flags(_screen) & TSM_SCREEN_HIDE_CURSOR) == 0;
}

- (void)setDelegate:(id <AGTerminalGridDelegate>)delegate
{
	_delegate = delegate;
}

- (id <AGTerminalGridDelegate>)delegate
{
	return _delegate;
}

@end
