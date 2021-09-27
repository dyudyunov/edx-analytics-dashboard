ROOT = $(shell echo "$$PWD")
COVERAGE_DIR = $(ROOT)/build/coverage

DJANGO_SETTINGS_MODULE ?= "analytics_dashboard.settings.local"

TOX=''

ifdef TOXENV
TOX := tox -- #to isolate each tox environment if TOXENV is defined
endif

define BROWSER_PYSCRIPT
import os, webbrowser, sys
try:
	from urllib import pathname2url
except:
	from urllib.request import pathname2url

webbrowser.open("file://" + pathname2url(os.path.abspath(sys.argv[1])))
endef
export BROWSER_PYSCRIPT
BROWSER := python -c "$$BROWSER_PYSCRIPT"

.PHONY: requirements coverage clean docs

# Generates a help message. Borrowed from https://github.com/pydanny/cookiecutter-djangopackage.
help: ## display this help message
	@echo "Please use \`make <target>\` where <target> is one of"
	@perl -nle'print $& if m{^[\.a-zA-Z_-]+:.*?## .*$$}' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m  %-25s\033[0m %s\n", $$1, $$2}'

requirements: requirements.py requirements.js

requirements.py: piptools
	pip-sync -q requirements/base.txt

requirements.js:
	npm install --unsafe-perm

test.requirements: piptools
	pip-sync -q requirements/test.txt

develop: piptools requirements.js
	pip-sync -q requirements/local.txt

migrate: ## apply database migrations
	$(TOX)python manage.py migrate  --run-syncdb

run-local: ## Run local (non-devstack) development server on port 8000
	python manage.py runserver 0.0.0.0:8110 --settings=analytics_dashboard.settings.local

dbshell-local: ## Run local (non-devstack) database shell
	python manage.py dbshell --settings=analytics_dashboard.settings.local

shell: ## Run Python shell
	python manage.py shell

clean: ## delete generated byte code and coverage reports
	find . -name '*.pyc' -delete
	find . -name '__pycache__' -type d -exec rm -rf {} ';' || true
	coverage erase
	rm -rf assets
	rm -rf pii_report

coverage: clean
	export COVERAGE_DIR=$(COVERAGE_DIR) && \
	$(TOX)pytest common analytics_dashboard --cov common --cov analytics_dashboard --cov-report html --cov-report xml

coverage_html: coverage ## run and view HTML coverage report
	$(BROWSER) build/coverage/html/index.html

test_python: clean ## run pyton tests and generate coverage report
	$(TOX)pytest common analytics_dashboard --cov common --cov analytics_dashboard

requirements.a11y:
	./.travis/a11y_reqs.sh

runserver_a11y:
	$(TOX)python manage.py runserver 0.0.0.0:9000 --noreload --traceback > dashboard.log 2>&1 &

accept: runserver_a11y
ifeq ("${DISPLAY_LEARNER_ANALYTICS}", "True")
	$(TOX)python manage.py waffle_flag enable_learner_analytics --create --everyone
endif
ifeq ("${ENABLE_COURSE_LIST_FILTERS}", "True")
	$(TOX)python manage.py waffle_switch enable_course_filters on --create
endif
ifeq ("${ENABLE_COURSE_LIST_PASSING}", "True")
	$(TOX)python ./manage.py waffle_switch enable_course_passing on --create
endif
	$(TOX)python manage.py create_acceptance_test_soapbox_messages
	$(TOX)pytest -v acceptance_tests --ignore=acceptance_tests/course_validation
	$(TOX)python manage.py delete_acceptance_test_soapbox_messages

# local acceptance tests are typically run with by passing in environment variables on the commandline
# e.g. API_SERVER_URL="http://localhost:9001/api/v0" API_AUTH_TOKEN="edx" make accept_local
accept_local:
	./manage.py create_acceptance_test_soapbox_messages
	pytest -v acceptance_tests --ignore=acceptance_tests/course_validation
	./manage.py delete_acceptance_test_soapbox_messages

accept_devstack:
	# TODO: implement this

a11y:
ifeq ("${DISPLAY_LEARNER_ANALYTICS}", "True")
	$(TOX)python manage.py waffle_flag enable_learner_analytics --create --everyone
endif
	cat dashboard.log
	$(TOX)pytest -v a11y_tests -k 'not NUM_PROCESSES==1' --ignore=acceptance_tests/course_validation

course_validation:
	python -m acceptance_tests.course_validation.generate_report

isort_check: ## check that isort has been run
	$(TOX)isort --check-only --recursive --diff acceptance_tests/ analytics_dashboard/ common/

isort: ## run isort to sort imports in all Python files
	$(TOX)isort --recursive --diff acceptance_tests/ analytics_dashboard/ common/

pycodestyle:  # run pycodestyle
	$(TOX)pycodestyle acceptance_tests analytics_dashboard common

pylint:  # run pylint
	$(TOX)pylint -j 0 --rcfile=pylintrc acceptance_tests analytics_dashboard common

# TODO: fix imports so this can run isort_check
quality: pycodestyle pylint ## run all code quality checks

validate_python: test_python quality

#FIXME validate_js: requirements.js
validate_js:
	npm run test
	npm run lint -s

validate: validate_python validate_js

demo:
	python manage.py waffle_switch show_engagement_forum_activity off --create
	python manage.py waffle_switch enable_course_api off --create
	python manage.py waffle_switch display_course_name_in_nav off --create

compile_translations: # compiles djangojs and django .po and .mo files
	$(TOX)python manage.py compilemessages

extract_translations: ## extract strings to be translated, outputting .mo files
	$(TOX)python manage.py makemessages -l en -v1 --ignore="docs/*" --ignore="src/*" --ignore="i18n/*" --ignore="assets/*" --ignore="static/bundles/*" -d django
	$(TOX)python manage.py makemessages -l en -v1 --ignore="docs/*" --ignore="src/*" --ignore="i18n/*" --ignore="assets/*" --ignore="static/bundles/*" -d djangojs

dummy_translations: ## generate dummy translation (.po) files
	cd analytics_dashboard && i18n_tool dummy

generate_fake_translations: extract_translations dummy_translations compile_translations ## generate and compile dummy translation files

pull_translations: ## pull translations from Transifex
	cd analytics_dashboard && tx pull -af

update_translations: pull_translations generate_fake_translations

detect_changed_source_translations: ## check if translation files are up-to-date
	cd analytics_dashboard && i18n_tool changed

# extract, compile, and check if translation files are up-to-date
validate_translations: extract_translations compile_translations detect_changed_source_translations
	cd analytics_dashboard && i18n_tool validate -

static: ## generate static files
	npm run build
	$(TOX)python manage.py collectstatic --noinput

pii_check: ## check for PII annotations on all Django models
	## Not yet implemented

piptools:
	pip3 install -q -r requirements/pip_tools.txt

export CUSTOM_COMPILE_COMMAND = make upgrade
upgrade: piptools ## update the requirements/*.txt files with the latest packages satisfying requirements/*.in
	pip-compile --upgrade -o requirements/pip_tools.txt requirements/pip_tools.in
	pip-compile --upgrade -o requirements/base.txt requirements/base.in
	pip-compile --upgrade -o requirements/doc.txt requirements/doc.in
	pip-compile --upgrade -o requirements/test.txt requirements/test.in
	pip-compile --upgrade -o requirements/tox.txt requirements/tox.in
	pip-compile --upgrade -o requirements/local.txt requirements/local.in
	pip-compile --upgrade -o requirements/optional.txt requirements/optional.in
	pip-compile --upgrade -o requirements/production.txt requirements/production.in
	pip-compile --upgrade -o requirements/travis.txt requirements/travis.in
	pip-compile --upgrade -o requirements/github.txt requirements/github.in
	# Let tox control the Django version for tests
	grep -e "^django==" requirements/base.txt > requirements/django.txt
	sed '/^[dD]jango==/d' requirements/test.txt > requirements/test.tmp
	mv requirements/test.tmp requirements/test.txt

docs:
	tox -e docs
