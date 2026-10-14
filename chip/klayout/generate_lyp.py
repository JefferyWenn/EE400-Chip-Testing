import sys
import xml.etree.ElementTree as ET

if len(sys.argv) != 3:
    print("Usage: python script.py input.layermap output.lyp")
    sys.exit(1)

input_file = sys.argv[1]
output_file = sys.argv[2]

layer_dict = {}
with open(input_file, "r") as f:
    for line in f:
        line = line.strip()
        if line.startswith('#') or not line:
            continue
        fields = [field.strip() for field in line.split()]
        if len(fields) != 4:
            print(f"Warning: Skipping line with {len(fields)} fields: {line}")
            continue
        layer_name, purpose, layer_num_str, datatype_num_str = fields
        try:
            layer_num = int(layer_num_str)
            datatype_num = int(datatype_num_str)
        except ValueError:
            print(f"Warning: Invalid layer or datatype number in line: {line}")
            continue
        key = (layer_num, datatype_num)
        if key not in layer_dict:
            layer_dict[key] = f"{layer_name} {purpose}"

root = ET.Element("layer-properties")
for (layer_num, datatype_num), name in layer_dict.items():
    properties = ET.SubElement(root, "properties")
    source = ET.SubElement(properties, "source")
    source.text = f"{layer_num}/{datatype_num}"
    name_elem = ET.SubElement(properties, "name")
    name_elem.text = name

tree = ET.ElementTree(root)
tree.write(output_file, encoding="utf-8", xml_declaration=True)
print(f"Successfully generated {output_file}")