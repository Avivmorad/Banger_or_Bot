-- Correct legacy repository links and licensing metadata for original fixtures.

begin;

update private.tracks
set
  source_url = 'https://github.com/Avivmorad/Banger-or-Bot/blob/main/client/public/audio/' || audio_filename,
  license_url = null,
  license_note = 'Original project audio. Copyright 2026 Aviv Morad; all rights reserved. See ASSET_LICENSE.md.'
where provider = 'project';

commit;
