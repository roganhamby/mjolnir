/// Model representing ASCII control characters and special whitespace characters
/// that can be copied to the clipboard or inserted into terminals and editors.
class SpecialCharacterItem {
  final String symbol;
  final String name;
  final String abbreviation;
  final String hexCode;
  final String value;
  final String description;

  const SpecialCharacterItem({
    required this.symbol,
    required this.name,
    required this.abbreviation,
    required this.hexCode,
    required this.value,
    required this.description,
  });

  String get displayName => '$symbol $name ($abbreviation / $hexCode)';

  static const List<SpecialCharacterItem> common = [
    SpecialCharacterItem(
      symbol: '^M',
      name: 'Carriage Return',
      abbreviation: 'CR',
      hexCode: '0x0D',
      value: '\r',
      description: 'Carriage return (ASCII 13 / 0x0D). Standard terminal ^M line break, dos2unix target, and Vim literal.',
    ),
    SpecialCharacterItem(
      symbol: '^J',
      name: 'Line Feed',
      abbreviation: 'LF',
      hexCode: '0x0A',
      value: '\n',
      description: 'Line feed / newline (ASCII 10 / 0x0A). Standard Unix line ending.',
    ),
    SpecialCharacterItem(
      symbol: '^I',
      name: 'Horizontal Tab',
      abbreviation: 'TAB',
      hexCode: '0x09',
      value: '\t',
      description: 'Horizontal tab character (ASCII 9 / 0x09).',
    ),
    SpecialCharacterItem(
      symbol: '^[',
      name: 'Escape',
      abbreviation: 'ESC',
      hexCode: '0x1B',
      value: '\x1b',
      description: 'Escape character (ASCII 27 / 0x1B). ANSI escape sequence prefix.',
    ),
    SpecialCharacterItem(
      symbol: '^@',
      name: 'Null Byte',
      abbreviation: 'NUL',
      hexCode: '0x00',
      value: '\x00',
      description: 'Null byte / zero terminator (ASCII 0 / 0x00).',
    ),
    SpecialCharacterItem(
      symbol: '^V',
      name: 'Literal Next / SYN',
      abbreviation: 'LNEXT',
      hexCode: '0x16',
      value: '\x16',
      description: 'Quoted-insert / literal-next control byte (ASCII 22 / 0x16). Tells terminals and editors to treat next key verbatim.',
    ),
    SpecialCharacterItem(
      symbol: '^C',
      name: 'Interrupt',
      abbreviation: 'ETX',
      hexCode: '0x03',
      value: '\x03',
      description: 'End of text / SIGINT interrupt byte (ASCII 3 / 0x03).',
    ),
    SpecialCharacterItem(
      symbol: '^D',
      name: 'End of File',
      abbreviation: 'EOT',
      hexCode: '0x04',
      value: '\x04',
      description: 'End of transmission / EOF byte (ASCII 4 / 0x04). Closes stdin or exits shells.',
    ),
    SpecialCharacterItem(
      symbol: '^Z',
      name: 'Substitute / Suspend',
      abbreviation: 'SUB',
      hexCode: '0x1A',
      value: '\x1a',
      description: 'Substitute / SIGTSTP background suspend byte (ASCII 26 / 0x1A).',
    ),
    SpecialCharacterItem(
      symbol: '^L',
      name: 'Form Feed',
      abbreviation: 'FF',
      hexCode: '0x0C',
      value: '\x0c',
      description: 'Form feed / clear screen redraw byte (ASCII 12 / 0x0C).',
    ),
    SpecialCharacterItem(
      symbol: '^H',
      name: 'Backspace',
      abbreviation: 'BS',
      hexCode: '0x08',
      value: '\x08',
      description: 'Backspace control byte (ASCII 8 / 0x08).',
    ),
    SpecialCharacterItem(
      symbol: '^?',
      name: 'Delete',
      abbreviation: 'DEL',
      hexCode: '0x7F',
      value: '\x7f',
      description: 'Delete / rubout byte (ASCII 127 / 0x7F).',
    ),
    SpecialCharacterItem(
      symbol: 'ZWSP',
      name: 'Zero-Width Space',
      abbreviation: 'ZWSP',
      hexCode: 'U+200B',
      value: '\u200B',
      description: 'Zero-width space invisible separator Unicode character.',
    ),
    SpecialCharacterItem(
      symbol: 'NBSP',
      name: 'Non-Breaking Space',
      abbreviation: 'NBSP',
      hexCode: 'U+00A0',
      value: '\u00A0',
      description: 'Non-breaking space Unicode character preventing line-wrapping.',
    ),
  ];
}
