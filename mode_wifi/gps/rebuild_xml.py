import json
import os
import sys

def build_xml(target_file, speed, dev_id):
    # run_gps_multi.sh와 완벽히 일치하는 파일명 사용
    output_path = f"/tmp/gps_prefs_{dev_id}.xml"
    
    if not os.path.exists(target_file):
        print(f" [-] Error: Route file {target_file} not found.")
        sys.exit(1)

    with open(target_file, "r") as f:
        coords = json.load(f)
    
    if not coords:
        print(" [-] Error: Empty coordinates in JSON.")
        sys.exit(1)

    display_name = os.path.splitext(os.path.basename(target_file))[0]
    
    entries = [
        '    <boolean name="noads" value="true" />',
        '    <boolean name="onettimeblock" value="true" />',
        '    <int name="pagbookmark" value="1" />',
        '    <int name="accion" value="0" />',
        f'    <float name="velocidad" value="{speed}" />'
    ]
    
    coord_str = ";".join([f"{lat},{lng}" for lat, lng in coords]) + ";"
    value = f"{display_name}+1+{speed}+0.0+{coord_str}"
    entries.append(f'    <string name="ruta0">{value}</string>')
    
    start_pt = f"{coords[0][0]},{coords[0][1]}"
    entries.append(f'    <string name="lastloc">CurrentStart+{start_pt}+15.0</string>')

    xml_content = "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n"
    xml_content += "\n".join(entries)
    xml_content += "\n</map>"
    
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(xml_content)
    
    print(f"[✓] XML Built for {dev_id} at {output_path}")

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python3 rebuild_xml.py <route_json> <speed> <dev_id>")
        sys.exit(1)
    build_xml(sys.argv[1], float(sys.argv[2]), sys.argv[3])
