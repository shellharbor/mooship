"""Verify the raw Compose template remains readable by dependency tooling."""

from pathlib import Path

import yaml


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    template = yaml.safe_load((root / "moodle/docker-compose.yml").read_text(encoding="utf-8"))
    services = template["services"]
    images = {name: service["image"] for name, service in services.items() if "image" in service}
    if not images or not all(isinstance(image, str) for image in images.values()):
        raise ValueError("The Compose template must expose its images to dependency tooling")
    if "{SLUG}" not in template["networks"]:
        raise ValueError("The raw template must retain the site network placeholder")
    for name, service in services.items():
        if not all(isinstance(network, str) for network in service.get("networks", [])):
            raise ValueError(f"Network references must be strings: {name}")
    print(f"Raw Compose YAML and {len(images)} image references passed")


if __name__ == "__main__":
    main()
