import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parent
cases = json.loads((root / 'capture-matrix.json').read_text(encoding='utf-8'))
font = ImageFont.truetype('C:/Windows/Fonts/consola.ttf', 18)
groups = [
    ('library', cases[0:4]),
    ('proposals-a', cases[4:7]),
    ('proposals-b', cases[7:9]),
    ('history', cases[9:13]),
    ('settings-a', cases[13:17]),
    ('settings-b', cases[17:20]),
    ('settings-c', cases[20:23]),
]
out = root / 'review-sheets'
out.mkdir(exist_ok=True)
for group, entries in groups:
    sheet = Image.new('RGB', (1296, len(entries) * 486), '#e8e8e8')
    draw = ImageDraw.Draw(sheet)
    for row, entry in enumerate(entries):
        for col, size in enumerate(['1440x900', '1280x800']):
            source = root / 'cases' / entry['id'] / ('page-' + size + '.png')
            with Image.open(source) as image:
                image = image.convert('RGB')
                image.thumbnail((640, 450), Image.Resampling.LANCZOS)
                x, y = col * 648, row * 486
                draw.text((x + 4, y + 4), entry['id'] + ' ' + size, fill='#222', font=font)
                sheet.paste(image, (x + 4, y + 32))
    sheet.save(out / (group + '.png'))
    print(out / (group + '.png'))
