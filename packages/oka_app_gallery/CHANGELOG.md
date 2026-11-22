# Changelog

All notable changes to `oka_app_gallery` are documented here. The release
train prepends sections per version — headings start with the exact
version.

## 0.12.0

- New package (ADR-0056 store/platform line): the AppGallery STORE package
  — `storeKeyAppGallery` plus the AppGallery Connect publish channel
  (`AppGalleryPublishTarget`, AGC REST upload tail, dry-run plans,
  credentials by path), carved out of `oka_huawei` so a store is no longer
  welded to the Huawei device platform.
