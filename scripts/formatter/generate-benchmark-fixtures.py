"""Generate deterministic, non-private formatting workloads; never execute SQL."""
import argparse
import json
from pathlib import Path


def record(index):
    return {
        "id": index, "label": f"워크플로우 항목 {index:06d}", "enabled": True,
        "retries": 3, "tags": ["alpha", "beta", "gamma"], "timeout": 5000,
    }


def piece(language, index):
    if language == "json":
        return json.dumps(record(index), ensure_ascii=False, separators=(",", ":"))
    if language == "yaml":
        return (f"  - id:     {index}\n    label:    '워크플로우 항목 {index:06d}'\n"
                "    enabled:   true\n    retries:   3\n    tags: [alpha,beta,gamma]\n"
                "    timeout:   5000\n")
    return (f"-- report {index:06d}\n"
            "select u.id,u.name,count(o.id) as order_count,sum(o.total) as order_total "
            "from users u left join orders o on o.user_id=u.id where u.active=1 "
            "and o.total>100 and u.region='서울' group by u.id,u.name "
            "having count(o.id)>2 order by order_total desc;\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for size in [32, 256]:
        for language in ["json", "yaml", "sql"]:
            prefix, separator, suffix = ('{"nodes":[', ",", "]}\n") if language == "json" else (
                ("nodes:\n", "", "") if language == "yaml" else ("", "", ""))
            parts = []
            byte_count = len((prefix + suffix).encode())
            while byte_count < size * 1024:
                text = piece(language, len(parts))
                byte_count += len(text.encode()) + (len(separator) if parts else 0)
                parts.append(text)
            data = (prefix + separator.join(parts) + suffix).encode()
            path = args.output / f"records-{size}k.{language}"
            path.write_bytes(data)
            print(f"{path.name}: bytes={len(data)} records={len(parts)}")


if __name__ == "__main__":
    main()
