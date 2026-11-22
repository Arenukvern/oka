// ADR-0056: the AppGallery channel is variant-free — capability
// declarations are the store/platform line made mechanical. The channel
// names the store and declares which platform postures its artifacts may
// carry; the build config is the delivery's business.
import 'package:oka_app_gallery/oka_app_gallery.dart';
import 'package:oka_core/oka_core.dart' show StoreKey;
import 'package:test/test.dart';

void main() {
  test('the channel is variant-free — the delivery owns the posture '
      '(ADR-0055)', () {
    const target = AppGalleryPublishTarget();
    expect(target.prohibitedOverlays, {'gms'});
    expect(target.acceptedPlatforms, {'android'});
    expect(target.acceptedArtifactFormats, {'aab'});
    // The build config no longer rides the channel — toString carries
    // no AndroidBuild restatement.
    expect(target.toString(), isNot(contains('AndroidBuild')));
    expect(target.description, contains('prohibits the gms overlay'));
  });

  test('the store key lives beside the channel (ADR-0056)', () {
    expect(storeKeyAppGallery.name, 'appgallery');
    expect(StoreKey.validate(storeKeyAppGallery.name), isNull);
  });
}
