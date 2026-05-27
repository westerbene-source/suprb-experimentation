from typing import Union, Callable, Any
import os
import numpy as np
import optuna
from sklearn.base import BaseEstimator
from sklearn.utils import Bunch
from datetime import datetime

from .base import ParameterTuner


class OptunaTuner(ParameterTuner):
    """
    Parameter tuning using optuna.
    """

    def __init__(
        self,
        estimator: BaseEstimator,
        X_train: np.ndarray,
        y_train: np.ndarray,
        scoring: Union[str, Callable] = "r2",
        callback: Union[Callable, list[Callable]] = None,
        tuner: str = "tpe",
        timeout: float = None,
        study_name: str = "NoName",
        **kwargs,
    ):
        super().__init__(estimator=estimator, X_train=X_train, y_train=y_train, scoring=scoring, **kwargs)

        self.callback = callback
        self.tuner = tuner
        self.timeout = timeout
        self.study_name = study_name

    def get_params(self):
        return super().get_params() | self._get_params(["timeout"])

    @staticmethod
    def _get_optimizer(tuner: str) -> Callable:
        return {
            "tpe": optuna.samplers.TPESampler,
            "cma-es": optuna.samplers.CmaEsSampler,
        }[tuner]

    def __call__(self, parameter_space: Callable, local_params: dict) -> tuple[dict, Any]:
        old_objective = self.generate_objective_function(**local_params)

        def objective(trial: optuna.Trial):
            params = parameter_space(trial)
            return old_objective(**params)

        sampler = self._get_optimizer(self.tuner)(seed=self.random_state)

        # VERBESSERUNG: PostgreSQL statt SQLite verwenden
        
        # Falls lokal via Devenv gestartet, nutzen wir den Unix-Socket-Pfad
        scratch_path = os.environ.get("SCRATCH")
        devenv_state = os.environ.get("DEVENV_STATE")

        if scratch_path:
            # Für die Ausführung im Slurm-Array (isoliert im Scratch des Tasks)
            storage_url = f"postgresql+psycopg2:///optuna_db?host={scratch_path}/postgres"
        elif devenv_state:
            # Lokal auf dem Login-Knoten via Devenv Shell
            storage_url = f"postgresql+psycopg2:///optuna_db?host={devenv_state}/postgres"
        else:
            storage_url = "postgresql+psycopg2://localhost/optuna_db"

        study = optuna.create_study(
            sampler=sampler,
            study_name=self.study_name,
            storage=storage_url,  # Hier wird die Postgres-URL übergeben
            load_if_exists=True,
        )

        self.tuned_params_ = parameter_space(study.best_trial)

        self.tuning_result_ = Bunch()
        self.tuning_result_.objective_history = [trial.value for trial in study.trials]
        self.tuning_result_.params_history = [trial.params for trial in study.trials]

        return self.tuned_params_, self.tuning_result_
