import 'package:mjolnir/models/special_character_item.dart';
import 'package:mjolnir/ui/stored_strings_tab_widget.dart';

void main() {
  print('Running Special Characters Tests...');

  // Test 1: Verify common special character items exist and have correct values
  final cr = SpecialCharacterItem.common.firstWhere((s) => s.symbol == '^M');
  assert(cr.value == '\r', 'Expected ^M value to be carriage return \\r');
  assert(cr.abbreviation == 'CR', 'Expected abbreviation to be CR');
  assert(cr.hexCode == '0x0D', 'Expected hexCode to be 0x0D');

  final lnext = SpecialCharacterItem.common.firstWhere((s) => s.symbol == '^V');
  assert(lnext.value == '\x16', 'Expected ^V value to be literal-next 0x16');
  assert(lnext.abbreviation == 'LNEXT', 'Expected abbreviation to be LNEXT');

  final esc = SpecialCharacterItem.common.firstWhere((s) => s.symbol == '^[');
  assert(esc.value == '\x1b', 'Expected ^[ value to be escape 0x1B');

  final tab = SpecialCharacterItem.common.firstWhere((s) => s.symbol == '^I');
  assert(tab.value == '\t', 'Expected ^I value to be tab');

  final nul = SpecialCharacterItem.common.firstWhere((s) => s.symbol == '^@');
  assert(nul.value == '\x00', 'Expected ^@ value to be null byte');

  // Verify all items have required fields
  for (final item in SpecialCharacterItem.common) {
    assert(item.symbol.isNotEmpty, 'Symbol must not be empty');
    assert(item.name.isNotEmpty, 'Name must not be empty');
    assert(item.value.isNotEmpty, 'Value must not be empty');
    assert(item.hexCode.isNotEmpty, 'HexCode must not be empty');
    assert(item.description.isNotEmpty, 'Description must not be empty');
  }

  // Test 2: normalizeMultilineValue preserves standalone carriage return \r
  final standaloneCr = StoredStringsTabWidget.normalizeMultilineValue('\r');
  assert(standaloneCr == '\r', 'Expected standalone \\r to be preserved, got: $standaloneCr');

  final textWithCr = StoredStringsTabWidget.normalizeMultilineValue('line1\rline2');
  assert(textWithCr == 'line1\rline2', 'Expected standalone \\r in text to be preserved');

  final crlf = StoredStringsTabWidget.normalizeMultilineValue('line1\r\nline2');
  assert(crlf == 'line1\nline2', 'Expected CRLF to be normalized to LF');

  // Test 3: formatDisplayValue converts single control chars to readable names
  assert(StoredStringsTabWidget.formatDisplayValue('\r') == '^M (Carriage Return / CR)');
  assert(StoredStringsTabWidget.formatDisplayValue('\n') == '^J (Line Feed / LF)');
  assert(StoredStringsTabWidget.formatDisplayValue('\t') == '^I (Tab)');
  assert(StoredStringsTabWidget.formatDisplayValue('\x1b') == '^[ (Escape / ESC)');
  assert(StoredStringsTabWidget.formatDisplayValue('\x16') == '^V (Literal Next / LNEXT)');
  assert(StoredStringsTabWidget.formatDisplayValue('normal text') == 'normal text');

  print('All Special Characters tests passed successfully!');
}
