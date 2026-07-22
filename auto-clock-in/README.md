# Auto Clock-In & Web Automation Scripts

This repository contains Selenium-based automation scripts to navigate websites, handle dynamic pop-ups, and manage elements that are obscured or hidden.

## Project Structure

*   **[main.py](file:///d:/Work/repos/devops-scripts/auto-clock-in/main.py)**: Automates interactions on `https://christhurajchurchmanjappara.com/` (printing links and clicking specific gallery albums).
*   **[exam.py](file:///d:/Work/repos/devops-scripts/auto-clock-in/exam.py)**: Automates navigation on `https://kapitel-zwei.de/`. It showcases best practices for handling cookie modals and avoiding `ElementNotInteractableException`.

---

## Getting Started

### Prerequisites
Make sure you have Python installed. Then, install the required packages:

```bash
pip install selenium webdriver-manager
```

### Running the Scripts

To run the main navigation script:
```bash
python main.py
```

To run the German language school language switcher automation:
```bash
python exam.py
```

---

## Advanced Selenium Techniques Demonstrated

### 1. Handling Cookie Consent & Privacy Preference Popups
Automated browsers start with empty profiles, meaning cookie banners will always appear. 
In [exam.py](file:///d:/Work/repos/devops-scripts/auto-clock-in/exam.py), we handle the Borlabs Cookie banner by waiting for the **"Nur essenzielle Cookies akzeptieren"** (accept essential only) button using an explicit wait:

```python
# Wait up to 10 seconds for the cookie banner's button to be clickable
essential_btn = WebDriverWait(driver, 10).until(
    EC.element_to_be_clickable((By.XPATH, "//button[contains(@class, 'brlbs-btn-accept-only-essential')]"))
)
essential_btn.click()

# Sleep briefly to let the overlay's fade-out animation complete
sleep(2)
```

### 2. Solving `ElementNotInteractableException`
If a link is present in the HTML but hidden (e.g., a mobile layout link when the desktop view is active), trying to click it directly results in an interactability exception. 

We solve this using a two-tiered strategy:
1.  **Check Visibility**: We use the `.is_displayed()` check to only interact with the visible version of the element.
2.  **JavaScript Fallback**: If the click is still intercepted by a fading transition overlay, we fall back to a JavaScript click `driver.execute_script("arguments[0].click();", element)`.

```python
links = driver.find_elements("xpath", "//a[@href]")
for link in links:
    if "https://kapitel-zwei.de/en/" in (link.get_attribute("href") or ""):
        if link.is_displayed():
            try:
                link.click()
                print("Successfully clicked the visible English flag.")
                break
            except Exception as click_err:
                print("Standard click was intercepted. Using JS fallback click.", click_err)
                driver.execute_script("arguments[0].click();", link)
                break
```

---

## Understanding XPath & `//` Operator

XPath (XML Path Language) is a syntax used to navigate and locate elements in HTML documents.

### Absolute vs. Relative Paths
*   **`/` (Single Slash)**: Starts selection from the root element or represents an immediate child. It is strict and breaks easily if the layout changes.
    *   *Example*: `/html/body/div/p`
*   **`//` (Double Slash)**: Starts selection from the current node and searches the entire document for matching elements, regardless of where they are nested.
    *   *Example*: `//p` searches for all `<p>` tags anywhere on the page.

### Commonly Used XPaths in this Repository
*   `//a[@href]`: Finds all anchor tags that have an `href` attribute.
*   `//button[contains(@class, 'brlbs-btn-accept-only-essential')]`: Finds any button element containing the specified class.
*   `//a[@data-title='കാലത്തിന്റെ കൈയൊപ്പ്']`: Finds anchor tags that have a specific Malayalam `data-title` attribute.

