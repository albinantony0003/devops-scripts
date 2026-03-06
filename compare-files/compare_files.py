import os

def compare_files(file1, file2):
    with open(file1, 'r') as f1:
        set1 = set(line.strip() for line in f1 if line.strip())
    
    with open(file2, 'r') as f2:
        set2 = set(line.strip() for line in f2 if line.strip())
    
    only_in_1 = sorted(list(set1 - set2))
    only_in_2 = sorted(list(set2 - set1))
    
    print(f"--- Unique to {os.path.basename(file1)} ({len(only_in_1)} items) ---")
    for item in only_in_1:
        print(item)
    
    print(f"\n--- Unique to {os.path.basename(file2)} ({len(only_in_2)} items) ---")
    for item in only_in_2:
        print(item)

if __name__ == "__main__":
    file1 = r"file-name-one"
    file2 = r"file-name-two"
    compare_files(file1, file2)
