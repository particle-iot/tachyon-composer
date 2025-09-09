import argparse
import xml.etree.ElementTree as ET

def modify_xml(file_path, label, field, value):
    """
    Modify the specified field of an XML element with the given label.
    """
    try:
        # Parse the XML file
        tree = ET.parse(file_path)
        root = tree.getroot()

        # Find the program element with the specified label
        found = False
        for program in root.findall("program"):
            if program.get("label") == label:
                # Modify the specified field
                program.set(field, value)
                found = True
                break

        if not found:
            print(f"Error: Label '{label}' not found in {file_path}.")
            return 1

        # Write changes back to the XML file
        tree.write(file_path, encoding="utf-8", xml_declaration=True)
        print(f"Successfully updated '{field}' for label '{label}' in {file_path}.")
        return 0

    except FileNotFoundError:
        print(f"Error: File '{file_path}' not found.")
        return 1
    except ET.ParseError as e:
        print(f"Error: Failed to parse XML. {e}")
        return 1

def main():
    parser = argparse.ArgumentParser(description="XML file utility.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Subparser for the 'modify' command
    modify_parser = subparsers.add_parser("modify", help="Modify a field in an XML file.")
    modify_parser.add_argument("--input", required=True, help="Path to the XML file to modify.")
    modify_parser.add_argument("--label", required=True, help="Label of the XML element to modify.")
    modify_parser.add_argument("--field", required=True, help="Field of the XML element to modify.")
    modify_parser.add_argument("--value", required=True, help="New value for the specified field.")

    args = parser.parse_args()

    if args.command == "modify":
        return modify_xml(args.input, args.label, args.field, args.value)

if __name__ == "__main__":
    exit(main())