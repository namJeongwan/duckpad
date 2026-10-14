// Takes ownership of a Lexilla lexer; large documents are styled on a snapshot.
#ifndef DPASYNCLEXER_H
#define DPASYNCLEXER_H
#ifdef __OBJC__
extern NSNotificationName const DPAsyncLexerDidStyleNotification;
#endif
constexpr int DPAsyncLexerPendingOperation = 0x44504153;
Scintilla::ILexer5 *DPWrapAsyncLexer(Scintilla::ILexer5 *lexer);
#endif
