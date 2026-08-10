/// Everywhere that is not the browser.
///
/// Returning false rather than throwing keeps the call site honest: the
/// caller has to say what it does instead, and on mobile that is copying
/// the file to the clipboard.
Future<bool> saveTextFile(String filename, String mimeType, String text) async {
  return false;
}
