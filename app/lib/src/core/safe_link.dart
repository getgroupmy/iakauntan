import 'package:url_launcher/url_launcher.dart';

/// Open a link that came from somewhere else.
///
/// `launchUrl` will hand a `javascript:` URI to `window.open` on the web,
/// and a `file:` or an app scheme to the platform handler everywhere
/// else. That is fine for a URL this application built; it is not fine
/// for one that arrived over the wire.
///
/// The one that arrives over the wire is `einvoice_documents.
/// validation_link`, which is whatever LHDN's MyInvois API put in its
/// response and which the e-Invoice screen turns into a button. Nobody
/// expects a tax authority to return `javascript:…`, but "nobody expects
/// this upstream to misbehave" is the assumption every supply-chain
/// incident is made of, and the check costs a line.
///
/// Returns false without launching anything if the scheme is not http or
/// https, so a caller can say so rather than appearing to do nothing.
Future<bool> launchExternal(String? url) async {
  if (url == null) return false;
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
