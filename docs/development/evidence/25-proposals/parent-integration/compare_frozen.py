import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops

repo = Path('C:/Project/network_config/info-manage')
qa = repo / '.scratch/25-merge-modal-captures'
results = []
for width in (1440, 1280):
    for state in ('confirm', 'save-failed'):
        name = f'purple-{width}-{state}.png'
        results.append((repo / 'docs/development/evidence/25-proposals/review-round4' / name,
                        qa / 'proposals' / name))
    for state in ('rotate', 'save-failure'):
        name = f'purple-{width}-{state}.png'
        results.append((repo / 'docs/development/evidence/27-credentials/r7' / name,
                        qa / 'credentials' / name))

report = []
for frozen, current in results:
    with Image.open(frozen) as old, Image.open(current) as new:
        assert old.size == new.size
        difference = ImageChops.difference(old.convert('RGB'), new.convert('RGB'))
        changed = sum(pixel != (0, 0, 0) for pixel in difference.get_flattened_data())
        paper_masks = []
        for image in (old, new):
            red, green, blue = image.convert('RGB').split()
            paper = ImageChops.multiply(
                ImageChops.multiply(red.point(lambda v: 255 if v == 255 else 0),
                                    green.point(lambda v: 255 if v == 253 else 0)),
                blue.point(lambda v: 255 if v == 253 else 0))
            paper_masks.append(paper.getbbox())
        modal_difference = difference.crop(paper_masks[1]).getbbox()
        report.append({
            'frozen': str(frozen), 'current': str(current), 'size': list(old.size),
            'frozenSha256': hashlib.sha256(frozen.read_bytes()).hexdigest(),
            'currentSha256': hashlib.sha256(current.read_bytes()).hexdigest(),
            'changedPixels': changed, 'differenceBounds': difference.getbbox(),
            'paperBounds': paper_masks, 'paperBoundsEqual': paper_masks[0] == paper_masks[1],
            'differenceInsideModalBounds': modal_difference,
        })

(qa / 'comparison.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
for row in report:
    print(f"{Path(row['current']).name}: changedPixels={row['changedPixels']}, bounds={row['differenceBounds']}, modalBounds={row['paperBounds']}, modalDifference={row['differenceInsideModalBounds']}")
