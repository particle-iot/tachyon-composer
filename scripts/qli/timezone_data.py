"""Validate the installed timezone database, including every advertised zone."""
from pathlib import Path
from zoneinfo import ZoneInfo


REQUIRED_ZONES = {
    'UTC', 'America/Denver', 'America/Los_Angeles', 'US/Mountain',
    'Africa/Johannesburg', 'America/Argentina/Buenos_Aires',
    'Antarctica/Casey', 'Arctic/Longyearbyen', 'Asia/Kolkata',
    'Atlantic/Azores', 'Australia/Sydney', 'Europe/London', 'Pacific/Auckland',
}


def verify_timezone_data(root):
    directory = Path(root) / 'usr/share/zoneinfo'
    zones = set(REQUIRED_ZONES)
    for table in ('zone.tab', 'zone1970.tab'):
        path = directory / table
        rows = [line.split() for line in path.read_text().splitlines()
                if line.strip() and not line.startswith('#')]
        if not rows or any(len(row) < 3 for row in rows):
            raise ValueError(f'Empty or invalid timezone table: {table}')
        zones.update(row[2] for row in rows)
    for zone in sorted(zones):
        path = directory / zone
        if not path.resolve().is_relative_to(directory.resolve()):
            raise ValueError(f'Timezone path escapes the database: {zone}')
        try:
            with path.open('rb') as stream:
                ZoneInfo.from_file(stream, key=zone)
        except (OSError, ValueError) as error:
            raise ValueError(f'Missing or invalid timezone: {zone}') from error
    return len(zones)
