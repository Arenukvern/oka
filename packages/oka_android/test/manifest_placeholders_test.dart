import 'package:oka_android/src/compilation/manifest_placeholders.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

const androidNs = 'http://schemas.android.com/apk/res/android';

void main() {
  const placeholders = ManifestPlaceholders(applicationId: 'dev.example.app');

  XmlElement elementOf(String xml) =>
      XmlDocument.parse(xml).rootElement;

  group('ManifestPlaceholders', () {
    test('substitutes the application id', () {
      expect(
        placeholders.substitute(
          r'${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
        ),
        'dev.example.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
      );
    });

    test('leaves an unknown placeholder untouched', () {
      expect(
        placeholders.substitute(r'${firebaseCollectionId}.provider'),
        r'${firebaseCollectionId}.provider',
      );
    });

    test('substitutes inside a longer value', () {
      expect(
        placeholders.substitute(r'prefix-${applicationId}-suffix'),
        'prefix-dev.example.app-suffix',
      );
    });

    test('leaves a value without placeholders untouched', () {
      expect(
        placeholders.substitute('android.permission.INTERNET'),
        'android.permission.INTERNET',
      );
    });

    test('substitutes every attribute of an element', () {
      final element = elementOf('''
<provider xmlns:android="$androidNs"
    android:authorities="${r'${applicationId}'}.fileprovider"
    android:process="${r'${applicationId}'}:push" />
''');

      placeholders.substituteInto(element);

      expect(
        element.getAttribute('authorities', namespaceUri: androidNs),
        'dev.example.app.fileprovider',
      );
      expect(
        element.getAttribute('process', namespaceUri: androidNs),
        'dev.example.app:push',
      );
    });

    test('substitutes nested elements', () {
      final document = XmlDocument.parse('''
<manifest xmlns:android="$androidNs">
  <application>
    <service android:name="${r'${applicationId}'}.Sync">
      <meta-data android:value="${r'${applicationId}'}.token" />
    </service>
  </application>
</manifest>
''');
      final service = document.rootElement
          .findElements('application')
          .first
          .findElements('service')
          .first;

      placeholders.substituteInto(service);

      expect(
        service.getAttribute('name', namespaceUri: androidNs),
        'dev.example.app.Sync',
      );
      final meta = service.findElements('meta-data').first;
      expect(
        meta.getAttribute('value', namespaceUri: androidNs),
        'dev.example.app.token',
      );
    });

    test('names the unresolved placeholders of a value', () {
      expect(
        ManifestPlaceholders.unresolvedIn(r'${a}.${b}.${a}'),
        {'a', 'b'},
      );
    });

    test('names the unresolved placeholders of an element', () {
      final element = elementOf('''
<uses-permission xmlns:android="$androidNs"
    android:name="${r'${applicationId}'}.PERMISSION" />
''');
      expect(
        ManifestPlaceholders.unresolvedInElement(element),
        {'applicationId'},
      );

      placeholders.substituteInto(element);
      expect(ManifestPlaceholders.unresolvedInElement(element), isEmpty);
    });
  });
}
